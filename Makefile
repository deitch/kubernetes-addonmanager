.PHONY: all tag image push

IMAGE ?= deitch/kubesync
HASH ?= $(shell git show --format=%T -s)

# check if we should append a dirty tag
DIRTY ?= $(shell git diff-index --quiet HEAD -- ; echo $$?)
ifneq ($(DIRTY),0)
TAG = $(HASH)-dirty
else
TAG = $(HASH)
endif

IMGTAG = $(IMAGE):$(TAG)

GITTEST ?= kubesync_git:test
TESTIMAGE ?= kubesync_tester:test
SOURCEDIR ?= ${CURDIR}/test

slash := /
escapeslash := \/

RUNNING = docker container ls | awk '/\s$(subst $(slash),$(escapeslash),$(IMAGE)):/ {print $$1}'
STOPPED = docker container ls -a | awk '/\s$(subst $(slash),$(escapeslash),$(IMAGE)):/ {print $$1}'
BUILTIMAGES = docker image ls | awk '/^$(subst $(slash),$(escapeslash),$(IMAGE))\s/ {print $$1":"$$2}'


.PHONY: all tag build image push test-start test-run test-run-interactive test-stop test build-test

all: push

tag:
	@echo $(TAG)

build: image

image:
	docker build -t $(IMGTAG) .

push: image
	docker push $(IMGTAG)

test-stop:
	cd test && docker-compose stop
	cd test && docker-compose rm -f

build-test:
	docker build -t $(TESTIMAGE) -f ./test/Dockerfile.test ./test/
	
# runs the entire test - its dependencies, then the test, then tear down
test: build build-test
	cd test && DEBUG=$(DEBUG) TOOLIMAGE=$(TESTIMAGE) IMAGE=$(IMGTAG) ./test.sh

test-debug:
	$(MAKE) test DEBUG=true

test-certs:
	cd test && openssl req -newkey rsa:2048 -keyout key.pem -nodes -x509 -days 365 -out certificate.pem -extensions req_ext  -config ./ssl.cnf


clean: test-stop
	@running=$$($(RUNNING)) ; if [ -n "$$running" ]; then docker stop $$running; fi
	@stopped=$$($(STOPPED)) ; if [ -n "$$stopped" ]; then docker rm $$stopped; fi
	@built=$$($(BUILTIMAGES)) ; if [ -n "$$built" ]; then docker image rm --no-prune $$built; fi
	@rm -rf test/tmp/*

cleanprune:
	@built=$$($(BUILTIMAGES)) ; if [ -n "$$built" ]; then docker image rm $$built; fi
	@rm -rf test/tmp/*

