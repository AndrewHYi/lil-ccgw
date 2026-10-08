# Budget terms

- **Local estimate:** Cost calculated from requests observed by the gateway.
  It can differ from the account's billed usage.
- **Billing baseline:** An observed account total at a particular time. The
  monthly estimate adds subsequent local request costs to this total.
- **UTC calendar month:** The period from the first day at 00:00 UTC through
  the next month's first day at 00:00 UTC.
- **Warning:** A budget threshold has been crossed, without blocking requests
  or changing their effort.
- **Block:** A budget prevents new requests from being forwarded.
- **Effort cap:** A limit on the effort requested from a model.
