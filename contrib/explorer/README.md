# BATHRON Explorer

Lightweight block explorer for the BATHRON network.

**Live:** [http://57.131.33.151:3001](http://57.131.33.151:3001)

## Features

- Latest blocks with auto-refresh (30s)
- Block details + transactions
- Transaction view (inputs/outputs with M0/M1 amounts)
- Address balance + history
- Search by block hash, tx hash, height, or address

## Run

Requires PHP and a running `bathrond` with RPC enabled.

```bash
# Configure RPC credentials in bathron-explorer.php
# then:
php -S 0.0.0.0:3001
```

## License

Same as BATHRON Core.
