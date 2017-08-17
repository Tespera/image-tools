# Environment checkup
ifndef IMAGE_DIR
$(error "No image directory specified (IMAGE_DIR)")
endif
include $(IMAGE_DIR)/env.mk
ifndef IMAGE_NAME
$(error "No image base name found (IMAGE_NAME), e.g. 'ubuntu'")
endif
ifndef IMAGE_VERSION
$(error "No image version found (IMAGE_VERSION), e.g. 'xenial'")
endif
ifndef IMAGE_TITLE
$(error "No image title found (IMAGE_TITLE), e.g. 'Ubuntu Xenial (16.04)'")
endif

DOCKER_NAMESPACE ?= scaleway
BUILD_OPTS ?=
SERVE_ROOTFS ?= y
SERVE_IP ?= $(shell scw-metadata --cached PUBLIC_IP_ADDRESS)

# Architecture variables setup
HOST_ARCH := $(shell uname -m)
ARCH ?=	$(HOST_ARCH)
ifneq ($(ARCH), $(HOST_ARCH))
$(shell docker run --rm --privileged multiarch/qemu-user-static:register --reset)
endif
ifeq ($(ARCH),arm)
	TARGET_QEMU_ARCH=arm
	TARGET_IMAGE_ARCH=arm
	TARGET_UNAME_ARCH=armv7l
	TARGET_DOCKER_TAG_ARCH=armhf
	TARGET_GOLANG_ARCH=arm
endif
ifeq ($(ARCH),armhf)
	TARGET_QEMU_ARCH=arm
	TARGET_IMAGE_ARCH=arm
	TARGET_UNAME_ARCH=armv7l
	TARGET_DOCKER_TAG_ARCH=armhf
	TARGET_GOLANG_ARCH=arm
endif
ifeq ($(ARCH),armv7l)
	TARGET_QEMU_ARCH=arm
	TARGET_IMAGE_ARCH=arm
	TARGET_UNAME_ARCH=armv7l
	TARGET_DOCKER_TAG_ARCH=armhf
	TARGET_GOLANG_ARCH=arm
endif
ifeq ($(ARCH),arm64)
	TARGET_QEMU_ARCH=aarch64
	TARGET_IMAGE_ARCH=arm64
	TARGET_UNAME_ARCH=arm64
	TARGET_DOCKER_TAG_ARCH=arm64
	TARGET_GOLANG_ARCH=arm64
endif
ifeq ($(ARCH),x86_64)
	TARGET_QEMU_ARCH=x86_64
	TARGET_IMAGE_ARCH=x86_64
	TARGET_UNAME_ARCH=x86_64
	TARGET_DOCKER_TAG_ARCH=amd64
	TARGET_GOLANG_ARCH=amd64
endif
ifeq ($(ARCH),amd64)
	TARGET_QEMU_ARCH=x86_64
	TARGET_IMAGE_ARCH=x86_64
	TARGET_UNAME_ARCH=x86_64
	TARGET_DOCKER_TAG_ARCH=amd64
	TARGET_GOLANG_ARCH=amd64
endif
EXPORT_DIR ?= $(IMAGE_DIR)/export/$(TARGET_IMAGE_ARCH)

# Default action: display usage
.PHONY: usage
usage:
	@echo 'Usage'
	@echo ' image                   build the Docker image'
	@echo ' rootfs.tar              export the Docker image to a rootfs.tar'
	@echo ' scaleway_image          create a Scaleway image, requires a working `scaleway-cli'
	@echo ' local_tests             run TIM tests against the Docker image'
	@echo ' tests                   run TIM tests against the image on Scaleway'

.PHONY: image
scaleway_image: $(EXPORT_DIR)/rootfs.tar

.PHONY: fclean
fclean: clean
	for tag in latest $(shell docker images | grep "^$(DOCKER_NAMESPACE)/$(IMAGE_NAME) " | awk '{print $$2}'); do\
	  echo "Creating a backup of '$(DOCKER_NAMESPACE)/$(IMAGE_NAME):$$tag' for caching"; \
	  docker tag $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$$tag old$(DOCKER_NAMESPACE)/$(IMAGE_NAME):$$tag; \
	  docker rmi -f $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$$tag; \
	done

.PHONY: clean
clean:
	-rm -f $(EXPORT_DIR)/rootfs.tar $(EXPORT_DIR)/export.tar
	-rm -rf $(EXPORT_DIR)/rootfs

image:
	docker build $(BUILD_OPTS) -t $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$(TARGET_DOCKER_TAG_ARCH)-$(IMAGE_VERSION) --build-arg ARCH=$(TARGET_DOCKER_TAG_ARCH) $(IMAGE_DIR)
	$(eval IMAGE_VERSION_ALIASES += $(shell date +%Y-%m-%d))
	$(foreach v,$(IMAGE_VERSION_ALIASES),docker tag $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$(TARGET_DOCKER_TAG_ARCH)-$(IMAGE_VERSION) $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$(TARGET_DOCKER_TAG_ARCH)-$v;)
	docker inspect -f '{{.Id}}' $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$(TARGET_DOCKER_TAG_ARCH)-$(IMAGE_VERSION)

$(EXPORT_DIR)/export.tar: image
	-mkdir -p $(EXPORT_DIR)/
	docker run --name $(IMAGE_NAME)-$(IMAGE_VERSION)-export --entrypoint /bin/true $(DOCKER_NAMESPACE)/$(IMAGE_NAME):$(TARGET_DOCKER_TAG_ARCH)-$(IMAGE_VERSION) 2>/dev/null || true
	docker export $(IMAGE_NAME)-$(IMAGE_VERSION)-export > $@.tmp
	docker rm $(IMAGE_NAME)-$(IMAGE_VERSION)-export
	mv $@.tmp $@

$(EXPORT_DIR)/rootfs: $(EXPORT_DIR)/export.tar
	-rm -rf $@ $@.tmp
	-mkdir -p $@.tmp
	tar -C $@.tmp -xf $<
	rm -f $@.tmp/.dockerenv $@.tmp/.dockerinit
	-chmod 1777 $@.tmp/tmp
	-chmod 755 $@.tmp/etc $@.tmp/usr $@.tmp/usr/local $@.tmp/usr/sbin
	-chmod 555 $@.tmp/sys
	-chmod 700 $@.tmp/root
	-mv $@.tmp/etc/hosts.default $@.tmp/etc/hosts || true
	echo "IMAGE_ID=\"$(TITLE)\"" >> $@.tmp/etc/scw-release
	echo "IMAGE_RELEASE=$(shell date +%Y-%m-%d)" >> $@.tmp/etc/scw-release
	echo "IMAGE_CODENAME=$(IMAGE_NAME)" >> $@.tmp/etc/scw-release
	echo "IMAGE_DESCRIPTION=\"$(DESCRIPTION)\"" >> $@.tmp/etc/scw-release
	echo "IMAGE_HELP_URL=\"$(HELP_URL)\"" >> $@.tmp/etc/scw-release
	echo "IMAGE_SOURCE_URL=\"$(SOURCE_URL)\"" >> $@.tmp/etc/scw-release
	echo "IMAGE_DOC_URL=\"$(DOC_URL)\"" >> $@.tmp/etc/scw-release
	mv $@.tmp $@

$(EXPORT_DIR)/rootfs.tar: $(EXPORT_DIR)/rootfs
	tar --format=gnu -C $< -cf $@.tmp .
	mv $@.tmp $@

.PHONY: rootfs.tar
rootfs.tar: $(EXPORT_DIR)/rootfs.tar
	ls -la $<
	@echo $<

.PHONY: scaleway_image
scaleway_image: rootfs.tar
ifeq ($(SERVE_ROOTFS), y)
	$(eval SERVE_PORT ?= $(shell shuf -i 10000-60000 -n 1))
	$(eval ROOTFS_URL := $(SERVE_IP):$(SERVE_PORT)/rootfs.tar)
	cd $(EXPORT_DIR) && python3 -m http.server $(SERVE_PORT) >/dev/null 2>&1 & echo $$!
	env OUTPUT_ID_TO=$(EXPORT_DIR)/image.id scripts/create_image.sh "$(IMAGE_TITLE)" "$(TARGET_IMAGE_ARCH)" "$(ROOTFS_URL)" "$(IMAGE_BOOTSCRIPT)"
	kill $$(lsof -i :$(SERVE_PORT) -t | tr '\n' ' ')
else
ifndef ROOTFS_URL
	$(error "Self httpd not enabled (SERVE_ROOTFS) and rootfs URL not provided (ROOTFS_URL)")
endif
	env OUTPUT_ID_TO=$(EXPORT_DIR)/image.id scripts/create_image.sh "$(IMAGE_TITLE)" "$(TARGET_IMAGE_ARCH)" "$(ROOTFS_URL)" "$(IMAGE_BOOTSCRIPT)"
endif

.PHONY: tests
tests: scaleway_image
	scripts/test_image.sh