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

test-start: 
	cd test && docker-compose up -d

test-stop:
	cd test && docker-compose stop
	cd test && docker-compose rm -f

test-run: build build-test test-start
	docker run --rm --network=kubesync -v /var/run/docker.sock:/var/run/docker.sock -v $(SOURCEDIR):/test -e DEBUG=$(DEBUG) -e RUNDIR=/test -e SOURCEDIR=$(SOURCEDIR) -e IMAGE=$(IMGTAG) $(TESTIMAGE) 
test-run-interactive: build build-test test-start
	docker run -it --rm --network=kubesync -v /var/run/docker.sock:/var/run/docker.sock -v $(SOURCEDIR):/test -e DEBUG=true -e RUNDIR=/test -e SOURCEDIR=$(SOURCEDIR)  -e IMAGE=$(IMGTAG) --entrypoint=sh $(TESTIMAGE)

build-test:
	docker build -t $(TESTIMAGE) -f ./test/Dockerfile.test ./test/
	
# runs the entire test - its dependencies, then the test, then tear down
test:
	$(MAKE) test-start
	$(MAKE) test-run
	$(MAKE) test-stop

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

