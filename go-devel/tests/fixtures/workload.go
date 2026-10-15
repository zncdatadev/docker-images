// A private SDK-compiled foreground workload; no external module or service.
package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
)

func run() error {
	const statePath = "/kubedoop/run/go-state"
	count := 0
	data, err := os.ReadFile(statePath)
	if err == nil {
		count, err = strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil {
			return fmt.Errorf("parse state: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read state: %w", err)
	}
	// os/signal owns sends; do not close its channel. Stop releases registration.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stop)
	if _, err := fmt.Println("TEST_GO_READY"); err != nil {
		return fmt.Errorf("announce readiness: %w", err)
	}
	<-stop
	if err := os.WriteFile(statePath, []byte(strconv.Itoa(count+1)+"\n"), 0o644); err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	if _, err := fmt.Println("TEST_GO_FLUSHED"); err != nil {
		return fmt.Errorf("announce flush: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		slog.Error("workload failed", "error", err)
		os.Exit(1)
	}
	os.Exit(42)
}
