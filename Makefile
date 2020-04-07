all: build

PREFIX?=staging-k8s.gcr.io
FLAGS=
ARCH?=amd64
ALL_ARCHITECTURES=amd64 arm arm64 ppc64le s390x
ML_PLATFORMS=linux/amd64,linux/arm,linux/arm64,linux/ppc64le,linux/s390x
GOLANG_VERSION?=1.11

ifndef TEMP_DIR
TEMP_DIR:=$(shell mktemp -d /tmp/heapster.XXXXXX)
endif

# This version is used as a tag for development images only.
VERSION?=dev
GIT_COMMIT:=$(shell git rev-parse --short HEAD)

ifdef REPO_DIR
DOCKER_IN_DOCKER=1
else
REPO_DIR:=$(shell pwd)
endif

# You can set this variable for testing and the built image will also be tagged with this name
OVERRIDE_IMAGE_NAME?=

# If this session isn't interactive, then we don't want to allocate a
# TTY, which would fail, but if it is interactive, we do want to attach
# so that the user can send e.g. ^C through.
INTERACTIVE := $(shell [ -t 0 ] && echo 1 || echo 0)
TTY=
ifeq ($(INTERACTIVE), 1)
	TTY=-t
endif

HEAPSTER_LDFLAGS=-w -X github.com/Stackdriver/heapster/version.HeapsterVersion=$(VERSION) -X github.com/Stackdriver/heapster/version.GitCommit=$(GIT_COMMIT)

fmt:
	find . -type f -name "*.go" | grep -v "./vendor*" | xargs gofmt -s -w

build: clean fmt
	GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags "$(HEAPSTER_LDFLAGS)" -o heapster github.com/Stackdriver/heapster/metrics
	GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags "$(HEAPSTER_LDFLAGS)" -o eventer github.com/Stackdriver/heapster/events

sanitize:
	hooks/check_boilerplate.sh
	hooks/check_gofmt.sh
	hooks/run_vet.sh

test-unit: clean sanitize build
ifeq ($(ARCH),amd64)
	GOARCH=$(ARCH) go test --test.short -race ./... $(FLAGS)
else
	GOARCH=$(ARCH) go test --test.short ./... $(FLAGS)
endif

test-unit-cov: clean sanitize build
	hooks/coverage.sh

build-in-container:
	# Run the build in a container in order to have reproducible builds
	# Also, fetch the latest ca certificates
	docker run --rm -i $(TTY) -v $(TEMP_DIR):/build -v $(REPO_DIR):/go/src/github.com/Stackdriver/heapster -w /go/src/github.com/Stackdriver/heapster golang:$(GOLANG_VERSION) /bin/bash -c "\
		cp /etc/ssl/certs/ca-certificates.crt /build \
		&& GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags \"$(HEAPSTER_LDFLAGS)\" -o /build/heapster github.com/Stackdriver/heapster/metrics \
		&& GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags \"$(HEAPSTER_LDFLAGS)\" -o /build/eventer github.com/Stackdriver/heapster/events"

container: build-in-container
	cp deploy/docker/Dockerfile $(TEMP_DIR)
	docker build -t $(PREFIX)/heapster-$(ARCH):$(VERSION) $(TEMP_DIR)
ifneq ($(OVERRIDE_IMAGE_NAME),)
	docker tag $(PREFIX)/heapster-$(ARCH):$(VERSION) $(OVERRIDE_IMAGE_NAME)
endif

ifndef DOCKER_IN_DOCKER
	rm -rf $(TEMP_DIR)
endif

push-one-arch: container
	gcloud docker -- push $(PREFIX)/heapster-$(ARCH):$(VERSION)

do-push:
	docker push $(PREFIX)/heapster-$(ARCH):$(VERSION)
ifeq ($(ARCH),amd64)
# TODO: Remove this and push the manifest list as soon as it's working
	docker tag $(PREFIX)/heapster-$(ARCH):$(VERSION) $(PREFIX)/heapster:$(VERSION)
	docker push $(PREFIX)/heapster:$(VERSION)
endif

# Should depend on target: ./manifest-tool
push: gcr-login $(addprefix sub-push-,$(ALL_ARCHITECTURES))
#	./manifest-tool push from-args --platforms $(ML_PLATFORMS) --template $(PREFIX)/heapster-ARCH:$(VERSION) --target $(PREFIX)/heapster:$(VERSION)

sub-push-%:
	$(MAKE) ARCH=$* PREFIX=$(PREFIX) VERSION=$(VERSION) container
	$(MAKE) ARCH=$* PREFIX=$(PREFIX) VERSION=$(VERSION) do-push

influxdb:
	ARCH=$(ARCH) PREFIX=$(PREFIX) make -C influxdb build

grafana:
	ARCH=$(ARCH) PREFIX=$(PREFIX) make -C grafana build

push-influxdb:
	PREFIX=$(PREFIX) make -C influxdb push

push-grafana:
	PREFIX=$(PREFIX) make -C grafana push

gcr-login:
ifeq ($(findstring gcr.io,$(PREFIX)),gcr.io)
	@echo "If you are pushing to a gcr.io registry, you have to be logged in via 'docker login'; 'gcloud docker push' can't push manifest lists yet."
	@echo "This script is automatically logging you in now with 'gcloud docker -a'"
	gcloud docker -a
endif

# TODO(luxas): As soon as it's working to push fat manifests to gcr.io, reenable this code
#./manifest-tool:
#	curl -sSL https://github.com/luxas/manifest-tool/releases/download/v0.3.0/manifest-tool > manifest-tool
#	chmod +x manifest-tool

clean:
	rm -f heapster
	rm -f eventer

.PHONY: all build sanitize test-unit test-unit-cov container grafana influxdb clean
