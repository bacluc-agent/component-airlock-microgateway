# Configure instance alias for commodore component compile
commodore_args += --alias $(instance)

MR ?= test-instance-01-redis-secret-sync

.PHONY: test-espejote
test-espejote: instance = $(espejote_instance)
test-espejote: commodore_args += -f tests/$(instance).yml
test-espejote: clean .compile ## Render all espejote ManagedResources and diff against expected output
	ESPEJOTE_CMD="$(ESPEJOTE_CMD)" ESPEJOTE_INSTANCE="$(espejote_instance)" bash tests/render/run.sh

.PHONY: test-espejote-one
test-espejote-one: instance = $(espejote_instance)
test-espejote-one: commodore_args += -f tests/$(instance).yml
test-espejote-one: clean .compile ## Render one espejote ManagedResource (MR=<dir under tests/render>) and diff against expected output
	ESPEJOTE_CMD="$(ESPEJOTE_CMD)" ESPEJOTE_INSTANCE="$(espejote_instance)" bash "tests/render/$(MR)/run.sh"

.PHONY: gen-espejote
gen-espejote: instance = $(espejote_instance)
gen-espejote: commodore_args += -f tests/$(instance).yml
gen-espejote: clean .compile ## Regenerate all espejote render output files, creating missing ones
	ESPEJOTE_CMD="$(ESPEJOTE_CMD)" ESPEJOTE_INSTANCE="$(espejote_instance)" bash tests/render/run.sh --update
