.PHONY: all tag image push

IMAGE ?= deitch/kubernetes-addon-manager
TAG ?= $(shell git show --format=%T -s)

all: push

tag:
	@echo $(TAG)

image:
	docker build -t $(IMAGE):$(TAG) .

push: image
	docker push $(IMAGE):$(TAG)

