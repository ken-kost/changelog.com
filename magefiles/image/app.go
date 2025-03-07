package image

import (
	"dagger.io/dagger"
)

const (
	// https://github.com/orgs/thechangelog/packages/container/package/changelog-legacy-assets
	LegacyAssetsImageRef = "ghcr.io/thechangelog/changelog-legacy-assets@sha256:4f1d2aa7036836bd59ff3af74bfd054c33a1ed558514a8dd91062a14804d7153"
)

func (image *Image) WithAppSrc() *Image {
	appSrc := image.dag.Host().Directory(".", dagger.HostDirectoryOpts{
		Include: []string{
			"config",
			"lib",
			"priv/repo",
			"test",
			"mix.exs",
			"mix.lock",
		},
	})

	image.container = image.container.
		WithDirectory("/app", appSrc).
		WithWorkdir("/app")

	return image
}

func (image *Image) WithAppDeps() *Image {
	image.container = image.container.
		WithMountedCache(
			"/app/deps", image.dag.CacheVolume("app-deps"),
		).
		WithExec([]string{
			"echo", "Fetch app deps...",
		}).
		WithExec([]string{
			"sh", "-c", "mix deps.get",
		}).
		WithExec([]string{
			"sh", "-c", "echo \"Ensure app deps are present & OK...\"",
		}).
		WithExec([]string{
			"sh", "-c", "ls -lahd /app/deps/*",
		}).
		WithMountedCache(
			"/app/_build", image.dag.CacheVolume("app-build"),
		).
		WithExec([]string{
			"sh", "-c", "echo \"Compile app $MIX_ENV deps...\"",
		}).
		WithExec([]string{
			"mix", "deps.compile",
		}).
		WithExec([]string{
			"sh", "-c", "echo \"Compile app for $MIX_ENV...\"",
		}).
		WithExec([]string{
			"mix", "compile",
		}).
		WithExec([]string{
			"sh", "-c", "echo \"Ensure $MIX_ENV bytecode is present & OK...\"",
		}).
		WithExec([]string{
			"sh", "-c", "ls -lahd /app/_build/$MIX_ENV/lib/*/ebin",
		})

	return image
}

func (image *Image) WithAppStaticAssets() *Image {
	appAssets := image.dag.Host().Directory("./assets", dagger.HostDirectoryOpts{
		Exclude: []string{
			"node_modules",
		},
	})

	image.container = image.container.
		WithDirectory("/app/assets", appAssets).
		WithWorkdir("/app/assets").
		WithMountedCache(
			"/app/assets/node_modules", image.dag.CacheVolume("app-node-modules"),
		).
		WithExec([]string{
			"yarn", "install", "--frozen-lockfile",
		}).
		WithExec([]string{
			"yarn", "run", "compile",
		}).
		WithWorkdir("/app").
		WithExec([]string{
			"mix", "phx.digest", "--no-vsn",
		}).
		WithExec([]string{
			"echo", "Ensure static assets are present & OK...",
		}).
		WithExec([]string{
			"ls", "-lah", "/app/priv/static/cache_manifest.json",
		})

	return image
}

func (image *Image) WithAppLegacyAssets() *Image {
	legacyAssets := image.NewContainer().
		From(LegacyAssetsImageRef).
		Directory("/var/www/wp-content")

	image.container = image.container.
		WithDirectory("/app/priv/static/wp-content", legacyAssets).
		WithExec([]string{
			"echo", "Ensure legacy assets are present & OK...",
		}).
		WithExec([]string{
			"ls", "-lah", "/app/priv/static/wp-content/uploads",
		})

	return image
}

func (image *Image) WithAppRelease() *Image {
	image.container = image.container.
		WithExec([]string{
			"echo", "Generate release files...",
		}).
		WithExec([]string{
			"mix", "phx.gen.release",
		}).
		WithExec([]string{
			"echo", "Create a self-contained release...",
		}).
		WithExec([]string{
			"mix", "release", "--path", "/app.release",
		}).
		WithExec([]string{
			"echo", "Check release version...",
		}).
		WithExec([]string{
			"/app.release/bin/changelog", "version",
		})

	return image
}
