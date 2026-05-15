# Real Time GO

> Never lose on time again.


## Setup

One needs [mise](https://mise.jdx.dev/). I used `2025.4.1`.

```
mise install
```

Create `mise.local.toml`:

```
[env]
SECRET_KEY_BASE = "dev"
SIGN_KEY = "this.one.should.be.rather.very.long"
```

## Develop

```
mise run dev
```

## Test

```
mise run test
```
