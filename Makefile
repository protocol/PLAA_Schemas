.PHONY: test test-docker
test:
	python3 scripts/test.py

test-docker:
	python3 scripts/test.py --docker
