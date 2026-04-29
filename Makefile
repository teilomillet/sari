.PHONY: validate

validate:
	git diff --check
	mix format --check-formatted
	mix test
