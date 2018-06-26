.PHONY: all tag image push

IMAGE ?= deitch/kubernetes-addonmanager
HASH ?= $(shell git show --format=%T -s)

# check if we should append a dirty tag
DIRTY ?= $(shell git diff-index --quiet HEAD -- ; echo $$?)
ifneq ($(DIRTY),0)
TAG = $(HASH)-dirty
else
TAG = $(HASH)
endif


all: push

tag:
	@echo $(TAG)

build: image

image:
	docker build -t $(IMAGE):$(TAG) .

push: image
	docker push $(IMAGE):$(TAG)
