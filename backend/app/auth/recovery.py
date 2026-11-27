import logging
import smtplib
import ssl
from email.message import EmailMessage

from email_validator import validate_email

from app.auth.account import create_recovery
from app.core.config import Settings

logger = logging.getLogger(__name__)


def smtp_delivery(settings: Settings, recipient: str, token: str, lifetime_minutes: int):
    if not all((settings.smtp_host, settings.smtp_username, settings.smtp_password, settings.smtp_from_email)):
        raise ValueError("SMTP is unconfigured")
    sender = validate_email(settings.smtp_from_email, check_deliverability=False).normalized
    message = EmailMessage()
    message["From"] = sender
    message["To"] = recipient
    message["Subject"] = "Expense Tracker password reset"
    message.set_content(
        f"Enter this code in the Expense Tracker app:\n\n{token}\n\n"
        f"It expires in {lifetime_minutes} minutes. Ignore this email if you did not request it."
    )
    context = ssl.create_default_context()
    options = {"timeout": settings.smtp_timeout_seconds}
    if settings.smtp_security == "tls":
        client = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, context=context, **options)
    else:
        client = smtplib.SMTP(settings.smtp_host, settings.smtp_port, **options)
    with client:
        if settings.smtp_security == "starttls":
            client.starttls(context=context)
        client.login(settings.smtp_username, settings.smtp_password.get_secret_value())
        client.send_message(message)


def recover_account(factory, email, lifetime, delivery, slots):
    try:
        if factory is None:
            return
        with factory() as db:
            recovery = create_recovery(db, email, lifetime)
        if recovery is not None:
            delivery(*recovery, lifetime)
    except Exception:
        # Transport errors can contain message data or provider credentials.
        logger.warning("Password recovery could not be completed")
    finally:
        slots.release()
