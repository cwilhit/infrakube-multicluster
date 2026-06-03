package multicluster

import (
	"context"
	"errors"
	"fmt"

	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	crmanager "sigs.k8s.io/controller-runtime/pkg/manager"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcmulticluster "sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

const LocalClusterName = ""

type Provider interface {
	mcmulticluster.Provider
	Run(context.Context, mcmanager.Manager) error
}

type Manager interface {
	mcmanager.Manager
	IsMulticluster() bool
	GetLocalManager() crmanager.Manager
	Start(context.Context) error
}

type manager struct {
	mcmanager.Manager
	provider Provider
}

func NewManager(cfg *rest.Config, provider Provider, opts ctrl.Options) (Manager, error) {
	var mcProvider mcmulticluster.Provider
	if provider != nil {
		mcProvider = provider
	}

	mgr, err := mcmanager.New(cfg, mcProvider, opts)
	if err != nil {
		return nil, err
	}

	return &manager{
		Manager:  mgr,
		provider: provider,
	}, nil
}

func WrapManager(localManager crmanager.Manager, provider Provider) (Manager, error) {
	var mcProvider mcmulticluster.Provider
	if provider != nil {
		mcProvider = provider
	}

	mgr, err := mcmanager.WithMultiCluster(localManager, mcProvider)
	if err != nil {
		return nil, err
	}

	return &manager{
		Manager:  mgr,
		provider: provider,
	}, nil
}

func (m *manager) IsMulticluster() bool {
	return m.provider != nil
}

func (m *manager) GetCluster(ctx context.Context, clusterName string) (cluster.Cluster, error) {
	return m.Manager.GetCluster(ctx, clusterName)
}

func (m *manager) GetLocalManager() crmanager.Manager {
	return m.Manager.GetLocalManager()
}

func (m *manager) Start(ctx context.Context) error {
	if m.provider == nil {
		return m.Manager.Start(ctx)
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	providerErr := make(chan error, 1)
	managerErr := make(chan error, 1)

	go func() {
		providerErr <- m.provider.Run(runCtx, m.Manager)
	}()
	go func() {
		managerErr <- m.Manager.Start(runCtx)
	}()

	select {
	case err := <-providerErr:
		cancel()
		if err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("multicluster provider stopped: %w", err)
		}
		return ignoreCanceled(<-managerErr)
	case err := <-managerErr:
		cancel()
		if err != nil && !errors.Is(err, context.Canceled) {
			return err
		}
		return ignoreCanceled(<-providerErr)
	}
}

func ignoreCanceled(err error) error {
	if errors.Is(err, context.Canceled) {
		return nil
	}
	return err
}
