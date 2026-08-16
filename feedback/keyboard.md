# Keyboard

## 2026-08-16

- Keyboard is not using suggestions from the phone keyboard.
- Slide-to-type does not work.
- Reason: input is registering **letter for letter** (per-key injection) instead of letting the OS keyboard compose text natively (autocomplete / swipe typing).
- Want: use the phone’s real keyboard IME so suggestions and glide typing work.
