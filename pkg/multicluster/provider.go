package multicluster

import (
	"context"
	"fmt"
	"sync"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	ctrl "sigs.k8s.io/controller-runtime/pkg/log"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcmulticluster "sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

const DefaultClusterNameLabel = "infrakube.galleybytes.com/cluster-name"

type ProviderOptions struct {
	Namespace        string
	SecretLabel      string
	KubeconfigKey    string
	ClusterNameLabel string
	ClusterOptions   []cluster.Option
}

type kubeconfigProvider struct {
	host cluster.Cluster
	opts ProviderOptions
	log  logr.Logger

	mu            sync.RWMutex
	clusters      map[string]*clusterEntry
	secretCluster map[string]string
	indexes       []indexRegistration
}

type clusterEntry struct {
	cluster  cluster.Cluster
	cancelFn context.CancelFunc
}

type indexRegistration struct {
	obj          client.Object
	field        string
	extractValue client.IndexerFunc
}

func NewKubeconfigProvider(host cluster.Cluster, opts ProviderOptions) Provider {
	if opts.Namespace == "" {
		opts.Namespace = "infrakube-system"
	}
	if opts.SecretLabel == "" {
		opts.SecretLabel = "infrakube.galleybytes.com/cluster"
	}
	if opts.KubeconfigKey == "" {
		opts.KubeconfigKey = "kubeconfig"
	}
	if opts.ClusterNameLabel == "" {
		opts.ClusterNameLabel = DefaultClusterNameLabel
	}

	return &kubeconfigProvider{
		host:          host,
		opts:          opts,
		log:           ctrl.Log.WithName("kubeconfig-cluster-provider"),
		clusters:      make(map[string]*clusterEntry),
		secretCluster: make(map[string]string),
	}
}

func (p *kubeconfigProvider) Run(ctx context.Context, mgr mcmanager.Manager) error {
	secretInformer, err := p.host.GetCache().GetInformer(ctx, &corev1.Secret{})
	if err != nil {
		return fmt.Errorf("getting secret informer: %w", err)
	}

	_, err = secretInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj any) {
			p.handleSecret(ctx, mgr, obj)
		},
		UpdateFunc: func(_, newObj any) {
			p.handleSecret(ctx, mgr, newObj)
		},
		DeleteFunc: func(obj any) {
			secret, ok := asSecret(obj)
			if !ok {
				return
			}
			p.disengageSecret(secretKey(secret), "secret deleted")
		},
	})
	if err != nil {
		return fmt.Errorf("adding secret event handler: %w", err)
	}

	<-ctx.Done()
	return ctx.Err()
}

func (p *kubeconfigProvider) Get(_ context.Context, clusterName string) (cluster.Cluster, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	entry, ok := p.clusters[clusterName]
	if !ok {
		return nil, mcmulticluster.ErrClusterNotFound
	}
	return entry.cluster, nil
}

func (p *kubeconfigProvider) IndexField(ctx context.Context, obj client.Object, field string, extractValue client.IndexerFunc) error {
	p.mu.Lock()
	p.indexes = append(p.indexes, indexRegistration{
		obj:          obj,
		field:        field,
		extractValue: extractValue,
	})
	p.mu.Unlock()

	if err := p.host.GetFieldIndexer().IndexField(ctx, obj, field, extractValue); err != nil {
		return fmt.Errorf("indexing host cluster field %q: %w", field, err)
	}
	for name, cl := range p.currentClusters() {
		if err := cl.GetFieldIndexer().IndexField(ctx, obj, field, extractValue); err != nil {
			return fmt.Errorf("indexing cluster %q field %q: %w", name, field, err)
		}
	}
	return nil
}

func (p *kubeconfigProvider) handleSecret(ctx context.Context, mgr mcmanager.Manager, obj any) {
	secret, ok := asSecret(obj)
	if !ok || !p.matches(secret) {
		if ok {
			p.disengageSecret(secretKey(secret), "secret no longer matches provider selector")
		}
		return
	}

	name := secretKey(secret)
	clusterName := p.clusterName(secret)
	kubeconfig := secret.Data[p.opts.KubeconfigKey]
	if len(kubeconfig) == 0 {
		p.log.Error(nil, "cluster secret is missing kubeconfig data", "secret", name, "key", p.opts.KubeconfigKey)
		p.disengageSecret(name, "secret missing kubeconfig")
		return
	}

	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfig)
	if err != nil {
		p.log.Error(err, "failed to parse cluster kubeconfig", "secret", name)
		p.disengageSecret(name, "invalid kubeconfig")
		return
	}

	p.disengageSecret(name, "cluster secret changed")
	p.disengage(clusterName, "cluster secret changed")

	cl, err := cluster.New(cfg, p.opts.ClusterOptions...)
	if err != nil {
		p.log.Error(err, "failed to create cluster", "cluster", clusterName, "secret", name)
		return
	}

	p.mu.RLock()
	indexes := append([]indexRegistration(nil), p.indexes...)
	p.mu.RUnlock()
	for _, idx := range indexes {
		if err := cl.GetFieldIndexer().IndexField(ctx, idx.obj, idx.field, idx.extractValue); err != nil {
			p.log.Error(err, "failed to index remote cluster field", "cluster", clusterName, "field", idx.field)
			return
		}
	}

	clusterCtx, cancel := context.WithCancel(ctx)
	p.mu.Lock()
	p.clusters[clusterName] = &clusterEntry{cluster: cl, cancelFn: cancel}
	p.secretCluster[name] = clusterName
	p.mu.Unlock()

	if err := mgr.Engage(clusterCtx, clusterName, cl); err != nil {
		cancel()
		p.mu.Lock()
		delete(p.clusters, clusterName)
		delete(p.secretCluster, name)
		p.mu.Unlock()
		utilruntime.HandleError(fmt.Errorf("failed to engage cluster %q: %w", clusterName, err))
		return
	}

	go func() {
		if err := cl.Start(clusterCtx); err != nil && clusterCtx.Err() == nil {
			p.log.Error(err, "remote cluster stopped", "cluster", clusterName)
		}
	}()
	p.log.Info("Engaged cluster", "cluster", clusterName, "secret", name)
}

func (p *kubeconfigProvider) disengage(clusterName, reason string) {
	p.mu.Lock()
	entry, ok := p.clusters[clusterName]
	if ok {
		delete(p.clusters, clusterName)
		for secret, mappedCluster := range p.secretCluster {
			if mappedCluster == clusterName {
				delete(p.secretCluster, secret)
			}
		}
	}
	p.mu.Unlock()
	if ok {
		entry.cancelFn()
		p.log.Info("Disengaged cluster", "cluster", clusterName, "reason", reason)
	}
}

func (p *kubeconfigProvider) disengageSecret(secret, reason string) {
	p.mu.RLock()
	clusterName := p.secretCluster[secret]
	p.mu.RUnlock()
	if clusterName != "" {
		p.disengage(clusterName, reason)
	}
}

func (p *kubeconfigProvider) matches(secret *corev1.Secret) bool {
	if secret.Namespace != p.opts.Namespace {
		return false
	}
	value, ok := secret.Labels[p.opts.SecretLabel]
	return ok && value == "true"
}

func (p *kubeconfigProvider) clusterName(secret *corev1.Secret) string {
	if name := secret.Labels[p.opts.ClusterNameLabel]; name != "" {
		return name
	}
	return secret.Name
}

func (p *kubeconfigProvider) currentClusters() map[string]cluster.Cluster {
	p.mu.RLock()
	defer p.mu.RUnlock()

	clusters := make(map[string]cluster.Cluster, len(p.clusters))
	for name, entry := range p.clusters {
		clusters[name] = entry.cluster
	}
	return clusters
}

func asSecret(obj any) (*corev1.Secret, bool) {
	switch typed := obj.(type) {
	case *corev1.Secret:
		return typed, true
	case cache.DeletedFinalStateUnknown:
		secret, ok := typed.Obj.(*corev1.Secret)
		return secret, ok
	default:
		return nil, false
	}
}

func secretKey(secret *corev1.Secret) string {
	return fmt.Sprintf("%s/%s", secret.Namespace, secret.Name)
}
