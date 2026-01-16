package image

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const (
	// Default Firecracker-compatible kernel and rootfs URLs
	// These are from the Firecracker quickstart guide
	DefaultKernelURL = "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
	DefaultRootfsURL = "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/rootfs/bionic.rootfs.ext4"

	DefaultKernelName = "vmlinux.bin"
	DefaultRootfsName = "rootfs.ext4"
)

// Manager handles kernel and rootfs image management
type Manager struct {
	KernelDir string
	RootfsDir string
}

// NewManager creates a new image manager
func NewManager(kernelDir, rootfsDir string) *Manager {
	return &Manager{
		KernelDir: kernelDir,
		RootfsDir: rootfsDir,
	}
}

// EnsureDefaultImages downloads default kernel and rootfs if not present
func (m *Manager) EnsureDefaultImages() error {
	kernelPath := filepath.Join(m.KernelDir, DefaultKernelName)
	rootfsPath := filepath.Join(m.RootfsDir, DefaultRootfsName)

	// Download kernel if not exists
	if _, err := os.Stat(kernelPath); os.IsNotExist(err) {
		fmt.Println("Downloading default kernel...")
		if err := m.downloadFile(DefaultKernelURL, kernelPath); err != nil {
			return fmt.Errorf("failed to download kernel: %w", err)
		}
		fmt.Println("Kernel downloaded successfully")
	}

	// Download rootfs if not exists
	if _, err := os.Stat(rootfsPath); os.IsNotExist(err) {
		fmt.Println("Downloading default rootfs (this may take a while)...")
		if err := m.downloadFile(DefaultRootfsURL, rootfsPath); err != nil {
			return fmt.Errorf("failed to download rootfs: %w", err)
		}
		fmt.Println("Rootfs downloaded successfully")
	}

	return nil
}

// GetDefaultKernelPath returns the path to the default kernel
func (m *Manager) GetDefaultKernelPath() string {
	return filepath.Join(m.KernelDir, DefaultKernelName)
}

// GetDefaultRootfsPath returns the path to the default rootfs
func (m *Manager) GetDefaultRootfsPath() string {
	return filepath.Join(m.RootfsDir, DefaultRootfsName)
}

// CreateVMRootfs creates a copy of the rootfs for a specific VM
func (m *Manager) CreateVMRootfs(vmName string, vmDir string) (string, error) {
	srcPath := m.GetDefaultRootfsPath()
	dstPath := filepath.Join(vmDir, vmName+".ext4")

	// Check if VM rootfs already exists
	if _, err := os.Stat(dstPath); err == nil {
		return dstPath, nil
	}

	// Check if source exists
	if _, err := os.Stat(srcPath); err != nil {
		return "", fmt.Errorf("default rootfs not found at %s: %w", srcPath, err)
	}

	// Copy the rootfs
	fmt.Printf("Creating rootfs for VM '%s'...\n", vmName)
	if err := copyFile(srcPath, dstPath); err != nil {
		return "", fmt.Errorf("failed to copy rootfs: %w", err)
	}

	return dstPath, nil
}

// DeleteVMRootfs removes a VM's rootfs
func (m *Manager) DeleteVMRootfs(vmName string, vmDir string) error {
	path := filepath.Join(vmDir, vmName+".ext4")
	if _, err := os.Stat(path); err == nil {
		return os.Remove(path)
	}
	return nil
}

// ListKernels returns all available kernels
func (m *Manager) ListKernels() ([]string, error) {
	return listFiles(m.KernelDir)
}

// ListRootfs returns all available rootfs images
func (m *Manager) ListRootfs() ([]string, error) {
	return listFiles(m.RootfsDir)
}

// downloadFile downloads a file from URL to the specified path
func (m *Manager) downloadFile(url, destPath string) error {
	// Ensure directory exists
	dir := filepath.Dir(destPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	// Create temp file
	tmpPath := destPath + ".tmp"
	out, err := os.Create(tmpPath)
	if err != nil {
		return err
	}
	defer out.Close()

	// Download
	resp, err := http.Get(url)
	if err != nil {
		os.Remove(tmpPath)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		os.Remove(tmpPath)
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	// Copy with progress (simple version)
	_, err = io.Copy(out, resp.Body)
	if err != nil {
		os.Remove(tmpPath)
		return err
	}

	// Rename to final path
	return os.Rename(tmpPath, destPath)
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

// listFiles returns all files in a directory
func listFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}

	var files []string
	for _, entry := range entries {
		if !entry.IsDir() {
			files = append(files, entry.Name())
		}
	}
	return files, nil
}
