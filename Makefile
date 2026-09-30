.PHONY: bootstrap fast fast-fix final-test format lint test test-serial test-portable swift-test package package-python clean-install install-pkg verify verify-portable release release-check clean

# The packaged app: build/macos-pkg/app/JR-Bar.app plus dist/JR-Bar-<version>.pkg,
# dist/JR-Bar-<version>.zip and, with the Sparkle key in the keychain,
# dist/appcast.xml. Signs with the best identity in the keychain and
# notarizes when the jrbar-notary profile exists (packaging/README.md).
VERSION := $(shell sed -n 's/^version = "\([^"]*\)"$$/\1/p' pyproject.toml | head -1)

bootstrap:
	./scripts/bootstrap-dev.sh

fast:
	.venv/bin/python scripts/verify_fast.py

fast-fix:
	.venv/bin/python scripts/verify_fast.py --fix

final-test:
	./scripts/final-test.sh

format: bootstrap
	.venv/bin/python -m ruff check --fix src tests packaging scripts

lint: bootstrap
	.venv/bin/python -m ruff check src tests packaging scripts

# One worker per core, each taking whole files: a file's tests share its
# fixtures and module state, and the conftest sandbox is per process.
# test-serial is the one-process run, for a failure that only shows there.
test: bootstrap
	.venv/bin/python -m pytest tests -q -n auto --dist loadfile

test-serial: bootstrap
	.venv/bin/python -m pytest tests -q

test-portable: bootstrap
	./scripts/verify.sh --no-bootstrap --portable --skip-build

# The app's Swift suites (SwiftPM, Command Line Tools). final-test runs this,
# so a crashing suite fails the final gate; `make package` and `make release`
# do not, so run final-test before them. `make fast` stays Python-only.
swift-test:
	cd app && swift test

package:
	./packaging/build_macos_pkg.sh

# Installs dist/JR-Bar-<version>.pkg for this user (~/Applications, no
# password: the distribution allows a home-directory install) after removing
# any JR-Bar.app already there, then opens it. `sudo installer -pkg
# dist/JR-Bar-$(VERSION).pkg -target /` is the /Applications install.
clean-install: install-pkg

install-pkg:
	@test -f dist/JR-Bar-$(VERSION).pkg || { echo "dist/JR-Bar-$(VERSION).pkg is missing: run make package" >&2; exit 1; }
	./scripts/install-agents.sh --pkg dist/JR-Bar-$(VERSION).pkg

# The Python wheel and sdist (developer artifacts), not the app.
package-python: bootstrap
	rm -rf build/python-release dist/jrbar-*.whl dist/jrbar-*.tar.gz
	.venv/bin/python -m build --no-isolation --outdir dist
	.venv/bin/python -m twine check dist/jrbar-*.whl dist/jrbar-*.tar.gz
	.venv/bin/python scripts/verify_clean_install.py

verify:
	./scripts/verify.sh

verify-portable:
	./scripts/verify.sh --portable

# The checked front door. release.sh refuses a dirty tree, a branch other than
# main, a local main that is not origin/main, a CHANGELOG top section that is
# not this version's or still says unreleased, an existing tag and a build
# number that did not go up, writes the notes, then hands off to
# scripts/publish_release.sh. It publishes.
release:
	./scripts/release.sh

# The same checks and the notes, with nothing published. The release gate,
# signing and the check for an existing GitHub release wait for publish time.
release-check:
	./scripts/release.sh --dry-run

clean:
	rm -rf build dist .pytest_cache .ruff_cache .coverage htmlcov
	find src tests packaging scripts -type d -name __pycache__ -prune -exec rm -rf {} +
