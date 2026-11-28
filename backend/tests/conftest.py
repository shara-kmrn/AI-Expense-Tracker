def pytest_configure(config):
    # Driver and SQLAlchemy frames can hold raw credentials even when the
    # exception is sanitized. Preserve normal stack traces without locals.
    config.option.showlocals = False
