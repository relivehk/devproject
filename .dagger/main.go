// Kuma Stand: локальный контур мониторинга Uptime Kuma (MariaDB, Prometheus, Grafana).
// Все команды управляют хостовым Docker через проброшенный /var/run/docker.sock.
package main

import (
	"context"
	"time"

	"dagger/kuma-stand/internal/dagger"
)

type KumaStand struct{}

const (
	dockerCli = "docker:28-cli"
	envPath   = "/run/secrets/env"
	appCompose = "compose/app/docker-compose.yml"
	monCompose = "compose/monitoring/docker-compose.yml"
)

// Базовый контейнер: docker CLI + compose, сокет хоста, исходники, .env как секрет.
func (m *KumaStand) base(source *dagger.Directory, docker *dagger.Socket, envFile *dagger.Secret) *dagger.Container {
	return dag.Container().
		From(dockerCli).
		WithExec([]string{"apk", "add", "--no-cache", "bash", "jq"}).
		WithUnixSocket("/var/run/docker.sock", docker).
		WithMountedDirectory("/src", source).
		WithMountedSecret(envPath, envFile).
		WithWorkdir("/src").
		// docker compose up — побочный эффект; без этого Dagger закэширует вызов и не выполнит повторно
		WithEnvVariable("CACHEBUSTER", time.Now().String())
}

// Поднимает MariaDB и Uptime Kuma (слой 1) и ждёт, пока оба станут healthy.
func (m *KumaStand) DeployApp(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	// Docker-сокет хоста: --docker=/var/run/docker.sock
	docker *dagger.Socket,
	// Файл .env с паролями: --env-file=file:.env
	envFile *dagger.Secret,
) (string, error) {
	return m.base(source, docker, envFile).
		WithExec([]string{"sh", "-c", "docker network create kuma-net 2>/dev/null || true"}).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", appCompose, "up", "-d", "--wait"}).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", appCompose, "ps"}).
		Stdout(ctx)
}

// Поднимает Prometheus, Grafana и экспортёры (слой 2).
func (m *KumaStand) DeployMonitoring(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
) (string, error) {
	return m.base(source, docker, envFile).
		WithExec([]string{"sh", "-c", "docker network create kuma-net 2>/dev/null || true"}).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", monCompose, "up", "-d", "--wait"}).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", monCompose, "ps"}).
		Stdout(ctx)
}

// Через Grafana HTTP API создаёт datasource Prometheus и импортирует дашборды из репозитория.
func (m *KumaStand) ConfigureGrafana(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
) (string, error) {
	// Вспомогательный контейнер запускается в сети kuma-net, иначе Grafana недостижима.
	script := `set -a; . ` + envPath + `; set +a
docker run --rm --network kuma-net \
  -v "$HOST_PROJECT_DIR/compose/monitoring/grafana/dashboards:/dash:ro" \
  -v "$HOST_PROJECT_DIR/scripts:/scripts:ro" \
  -e GRAFANA_ADMIN_USER -e GRAFANA_ADMIN_PASSWORD \
  alpine:3.21 sh /scripts/configure-grafana.sh`
	return m.base(source, docker, envFile).
		WithExec([]string{"sh", "-c", script}).
		Stdout(ctx)
}

// Поднимает всю платформу и валидирует статус всех систем.
func (m *KumaStand) DeployAll(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
) (string, error) {
	out := ""
	for _, step := range []func(context.Context, *dagger.Directory, *dagger.Socket, *dagger.Secret) (string, error){
		m.DeployApp, m.DeployMonitoring, m.ConfigureGrafana,
	} {
		s, err := step(ctx, source, docker, envFile)
		if err != nil {
			return out, err
		}
		out += s + "\n"
	}
	v, err := m.Validate(ctx, source, docker, envFile)
	return out + v, err
}

// Проверяет контейнеры, targets Prometheus и дашборд в Grafana.
func (m *KumaStand) Validate(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
) (string, error) {
	return m.base(source, docker, envFile).
		WithExec([]string{"bash", "scripts/validate.sh"}).
		Stdout(ctx)
}

// Chaos-тест: останавливает контейнер и проверяет переход в DOWN и восстановление.
func (m *KumaStand) Chaos(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
	// Контейнер: mariadb или uptime-kuma
	// +default="mariadb"
	target string,
	// stop (по ТЗ; возврат через docker start) или kill (возврат по restart-policy)
	// +default="stop"
	mode string,
) (string, error) {
	return m.base(source, docker, envFile).
		WithExec([]string{"bash", "scripts/chaos.sh", target, mode}).
		Stdout(ctx)
}

// Останавливает и удаляет оба стека (volumes сохраняются).
func (m *KumaStand) Destroy(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".env", "**/.env"]
	source *dagger.Directory,
	docker *dagger.Socket,
	envFile *dagger.Secret,
) (string, error) {
	return m.base(source, docker, envFile).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", monCompose, "down"}).
		WithExec([]string{"docker", "compose", "--env-file", envPath, "-f", appCompose, "down"}).
		WithExec([]string{"sh", "-c", "echo stacks removed, volumes kept"}).
		Stdout(ctx)
}
