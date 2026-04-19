package controllers

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"sigs.k8s.io/controller-runtime/pkg/log"
)

// CacheServer serves terraform binaries from a persistent cache directory.
// It implements the controller-runtime Runnable interface so the manager
// starts and stops it alongside the reconciler.
type CacheServer struct {
	CacheDir string
	Addr     string
}

func (s *CacheServer) Start(ctx context.Context) error {
	logger := log.FromContext(ctx).WithName("cache-server")

	if err := os.MkdirAll(s.CacheDir, 0o755); err != nil {
		return fmt.Errorf("creating cache dir: %w", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/terraform/versions", s.handleListVersions)
	mux.HandleFunc("/api/v1/terraform/", s.handleBinary)

	srv := &http.Server{Addr: s.Addr, Handler: mux}

	go func() {
		<-ctx.Done()
		logger.Info("shutting down cache server")
		srv.Close()
	}()

	logger.Info("starting cache server", "addr", s.Addr, "cacheDir", s.CacheDir)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// handleBinary handles GET and PUT for /api/v1/terraform/{version}?arch={arch}
func (s *CacheServer) handleBinary(w http.ResponseWriter, r *http.Request) {
	version := strings.TrimPrefix(r.URL.Path, "/api/v1/terraform/")
	if version == "" || version == "versions" {
		http.Error(w, "missing version", http.StatusBadRequest)
		return
	}

	arch := r.URL.Query().Get("arch")
	if arch == "" {
		arch = "amd64"
	}

	binPath := filepath.Join(s.CacheDir, arch, version)

	switch r.Method {
	case http.MethodGet:
		s.serveBinary(w, r, binPath, version, arch)
	case http.MethodPut:
		s.storeBinary(w, r, binPath, version, arch)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *CacheServer) serveBinary(w http.ResponseWriter, r *http.Request, binPath, version, arch string) {
	logger := log.FromContext(r.Context()).WithName("cache-server")

	f, err := os.Open(binPath)
	if err != nil {
		if os.IsNotExist(err) {
			http.NotFound(w, r)
			return
		}
		logger.Error(err, "opening cached binary", "version", version, "arch", arch)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	io.Copy(w, f)
	logger.Info("served cached binary", "version", version, "arch", arch)
}

func (s *CacheServer) storeBinary(w http.ResponseWriter, r *http.Request, binPath, version, arch string) {
	logger := log.FromContext(r.Context()).WithName("cache-server")

	dir := filepath.Dir(binPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		logger.Error(err, "creating arch dir", "arch", arch)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	f, err := os.Create(binPath)
	if err != nil {
		logger.Error(err, "creating cache file", "version", version, "arch", arch)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	n, err := io.Copy(f, r.Body)
	if err != nil {
		logger.Error(err, "writing cache file", "version", version, "arch", arch)
		os.Remove(binPath)
		http.Error(w, "write error", http.StatusInternalServerError)
		return
	}

	if err := os.Chmod(binPath, 0o755); err != nil {
		logger.Error(err, "chmod cache file", "version", version, "arch", arch)
	}

	logger.Info("cached binary", "version", version, "arch", arch, "bytes", n)
	w.WriteHeader(http.StatusCreated)
}

// handleListVersions returns all cached versions as a plain text list.
func (s *CacheServer) handleListVersions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var versions []string
	archDirs, err := os.ReadDir(s.CacheDir)
	if err != nil {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "no cached versions")
		return
	}

	for _, archDir := range archDirs {
		if !archDir.IsDir() {
			continue
		}
		entries, err := os.ReadDir(filepath.Join(s.CacheDir, archDir.Name()))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				versions = append(versions, fmt.Sprintf("%s/%s", archDir.Name(), e.Name()))
			}
		}
	}

	sort.Strings(versions)
	w.Header().Set("Content-Type", "text/plain")
	for _, v := range versions {
		fmt.Fprintln(w, v)
	}
}
