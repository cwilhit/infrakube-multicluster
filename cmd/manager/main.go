package manager

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	// Import all Kubernetes client auth plugins (e.g. Azure, GCP, OIDC, etc.)
	"github.com/galleybytes/infrakube/pkg/apis"
	infrakubev1 "github.com/galleybytes/infrakube/pkg/apis/infrakube/v1"
	"github.com/galleybytes/infrakube/pkg/controllers"
	"github.com/galleybytes/infrakube/pkg/multicluster"
	localcache "github.com/patrickmn/go-cache"
	"go.uber.org/zap/zapcore"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	_ "k8s.io/client-go/plugin/pkg/client/auth"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(apis.AddToScheme(scheme))
	// +kubebuilder:scaffold:scheme
}

func StartInfrakube() {
	var metricsAddr string
	var enableLeaderElection bool
	var probeAddr string
	var maxConcurrentReconciles int
	var disableReconciler bool
	var inheritNodeSelector bool
	var inheritAffinty bool
	var inheritTolerations bool
	var requireApprovalImage string
	var cacheDir string
	var cacheURL string
	var autoDownload bool
	var tfDownloadBaseURL string
	var taskImage string
	var tofuDownloadBaseURL string
	var enableMulticluster bool
	var clusterSecretsNamespace string
	var clusterSecretsLabel string
	var clusterSecretsKubeconfigKey string
	var clusterNameLabel string

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&disableReconciler, "disable-reconciler", false, "Set to true to disable the reconcile loop controller)")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Enable leader election for controller manager. "+
			"Enabling this will ensure there is only one active controller manager.")
	flag.IntVar(&maxConcurrentReconciles, "max-concurrent-reconciles", 1, "The max number of concurrent Reconciles for the controller")
	flag.BoolVar(&inheritNodeSelector, "inherit-node-selector", false, "Use the controller's nodeSelector for every task created by the controller")
	flag.BoolVar(&inheritAffinty, "inherit-affinity", false, "Use the controller's affinity rules for every task created by the controller")
	flag.BoolVar(&inheritTolerations, "inherit-tolerations", false, "Use the controller's tolerations for every task created by the controller")
	flag.StringVar(&requireApprovalImage, "require-approval-image", "ghcr.io/galleybytes/require-approval:0.2.0", "Plugin image for require-approval")
	flag.StringVar(&cacheDir, "cache-dir", "/var/cache/infrakube/terraform", "Directory for the terraform binary cache")
	flag.StringVar(&cacheURL, "cache-url", "http://infrakube-controller.infrakube-system.svc:8082", "URL of the cache server injected into task pods")
	flag.BoolVar(&autoDownload, "auto-download", true, "Allow task pods to automatically download Terraform or OpenTofu binaries from the internet")
	flag.StringVar(&tfDownloadBaseURL, "tf-download-base-url", "https://releases.hashicorp.com/terraform", "Base URL for Terraform release downloads")
	flag.StringVar(&tofuDownloadBaseURL, "tofu-download-base-url", "https://github.com/opentofu/opentofu/releases/download", "Base URL for OpenTofu release downloads")
	flag.BoolVar(&enableMulticluster, "enable-multicluster", false, "Watch labeled kubeconfig Secrets and reconcile resources across multiple clusters")
	flag.StringVar(&clusterSecretsNamespace, "cluster-secrets-namespace", "infrakube-system", "Namespace containing labeled kubeconfig Secrets for multicluster mode")
	flag.StringVar(&clusterSecretsLabel, "cluster-secrets-label", "infrakube.galleybytes.com/cluster", "Boolean label used to select kubeconfig Secrets for multicluster mode")
	flag.StringVar(&clusterSecretsKubeconfigKey, "cluster-secrets-key", "kubeconfig", "Secret data key containing a kubeconfig for multicluster mode")
	flag.StringVar(&clusterNameLabel, "cluster-name-label", multicluster.DefaultClusterNameLabel, "Optional Secret label containing the logical cluster name for multicluster mode")
	taskImageDefault := os.Getenv("INFRAKUBE_TASK_IMAGE")
	if taskImageDefault == "" {
		taskImageDefault = fmt.Sprintf("%s:%s", infrakubev1.TaskImageRepoDefault, infrakubev1.TaskImageTagDefault)
	}
	flag.StringVar(&taskImage, "task-image", taskImageDefault, "Default task image for terraform, setup, and script tasks when spec.images is not set")
	opts := zap.Options{
		Development: true,
		Level:       zapcore.DebugLevel,
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	globalEnvFromConfigmapData := make(map[string]string)
	globalEnvFromSecretData := make(map[string][]byte)
	for _, env := range os.Environ() {
		key := strings.Split(env, "=")[0]
		if strings.HasPrefix(key, "INFRAKUBE_VAR_") {

			globalEnvFromConfigmapData[strings.TrimPrefix(key, "INFRAKUBE_VAR_")] = os.Getenv(key)

		}
		if strings.HasPrefix(key, "INFRAKUBE_SECRET_") {
			globalEnvFromSecretData[strings.TrimPrefix(key, "INFRAKUBE_SECRET_")] = []byte(os.Getenv(key))
		}
	}

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	c := localcache.New(60*time.Second, 3600*time.Second)

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		// MetricsBindAddress:     metricsAddr,
		// Port:                   9443,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "050c8fba.galleybytes.com",
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	var provider multicluster.Provider
	if enableMulticluster {
		provider = multicluster.NewKubeconfigProvider(mgr, multicluster.ProviderOptions{
			Namespace:        clusterSecretsNamespace,
			SecretLabel:      clusterSecretsLabel,
			KubeconfigKey:    clusterSecretsKubeconfigKey,
			ClusterNameLabel: clusterNameLabel,
			ClusterOptions: []cluster.Option{
				func(opts *cluster.Options) {
					opts.Scheme = scheme
				},
			},
		})
	}

	mcMgr, err := multicluster.WrapManager(mgr, provider)
	if err != nil {
		setupLog.Error(err, "unable to create multicluster manager")
		os.Exit(1)
	}

	clientForCluster := func(ctx context.Context, clusterName string) (client.Client, error) {
		cl, err := mcMgr.GetCluster(ctx, clusterName)
		if err != nil {
			return nil, err
		}
		return cl.GetClient(), nil
	}
	recorderForCluster := func(name string) func(context.Context, string) (record.EventRecorder, error) {
		return func(ctx context.Context, clusterName string) (record.EventRecorder, error) {
			cl, err := mcMgr.GetCluster(ctx, clusterName)
			if err != nil {
				return nil, err
			}
			return cl.GetEventRecorderFor(name), nil
		}
	}

	if !disableReconciler {
		if err = (&controllers.ReconcileTf{
			Client:                     mgr.GetClient(),
			LocalClient:                mgr.GetClient(),
			ClientForCluster:           clientForCluster,
			RecorderForCluster:         recorderForCluster("tf-controller"),
			Log:                        ctrl.Log.WithName("tf_controller"),
			Recorder:                   mgr.GetEventRecorderFor("tf-controller"),
			Scheme:                     mgr.GetScheme(),
			MaxConcurrentReconciles:    maxConcurrentReconciles,
			Cache:                      c,
			GlobalEnvFromConfigmapData: globalEnvFromConfigmapData,
			GlobalEnvFromSecretData:    globalEnvFromSecretData,
			GlobalEnvSuffix:            "global-envs",
			InheritAffinity:            inheritAffinty,
			AffinityCacheKey:           "inherited_affinity",
			InheritNodeSelector:        inheritNodeSelector,
			NodeSelectorCacheKey:       "inherited_nodeselector",
			InheritTolerations:         inheritTolerations,
			TolerationsCacheKey:        "inherited_tolerations",
			RequireApprovalImage:       requireApprovalImage,
			CacheURL:                   cacheURL,
			AutoDownload:               autoDownload,
			TfDownloadBaseURL:          tfDownloadBaseURL,
			TaskImage:                  taskImage,
		}).SetupWithManager(mcMgr); err != nil {
			setupLog.Error(err, "unable to create controller", "controller", "Terraform")
			os.Exit(1)
		}

		if err = (&controllers.ReconcileTofu{
			Client:                     mgr.GetClient(),
			LocalClient:                mgr.GetClient(),
			ClientForCluster:           clientForCluster,
			RecorderForCluster:         recorderForCluster("tofu-controller"),
			Log:                        ctrl.Log.WithName("tofu_controller"),
			Recorder:                   mgr.GetEventRecorderFor("tofu-controller"),
			Scheme:                     mgr.GetScheme(),
			MaxConcurrentReconciles:    maxConcurrentReconciles,
			Cache:                      c,
			GlobalEnvFromConfigmapData: globalEnvFromConfigmapData,
			GlobalEnvFromSecretData:    globalEnvFromSecretData,
			GlobalEnvSuffix:            "global-envs",
			InheritAffinity:            inheritAffinty,
			AffinityCacheKey:           "inherited_affinity",
			InheritNodeSelector:        inheritNodeSelector,
			NodeSelectorCacheKey:       "inherited_nodeselector",
			InheritTolerations:         inheritTolerations,
			TolerationsCacheKey:        "inherited_tolerations",
			RequireApprovalImage:       requireApprovalImage,
			CacheURL:                   cacheURL,
			AutoDownload:               autoDownload,
			TofuDownloadBaseURL:        tofuDownloadBaseURL,
			TaskImage:                  taskImage,
		}).SetupWithManager(mcMgr); err != nil {
			setupLog.Error(err, "unable to create controller", "controller", "Tofu")
			os.Exit(1)
		}
	}
	// +kubebuilder:scaffold:builder
	if err := mcMgr.GetFieldIndexer().IndexField(context.TODO(), &corev1.Pod{}, "metadata.generateName", func(obj client.Object) []string {
		return []string{obj.(*corev1.Pod).ObjectMeta.GenerateName}
	}); err != nil {
		panic(err)
	}

	cacheServer := &controllers.CacheServer{
		CacheDir: cacheDir,
		Addr:     ":8082",
	}
	if err := mgr.Add(cacheServer); err != nil {
		setupLog.Error(err, "unable to add cache server")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("health", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("check", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mcMgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
