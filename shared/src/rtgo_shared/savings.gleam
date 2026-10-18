/// A bounded bank. The next stored stone costs (balance + 1) base intervals.
/// Spending preserves fractional recharge progress at the new recharge rate.
import gleam/int

pub type Bank {
  Bank(credits: Int, progress_ms: Int, updated_at: Int, available_at: Int)
}

pub fn new(now: Int) -> Bank {
  Bank(0, 0, now, now)
}

pub fn advance(bank: Bank, now: Int, interval: Int, capacity: Int) -> Bank {
  let elapsed = int.max(0, now - bank.updated_at)
  fill(
    Bank(..bank, progress_ms: bank.progress_ms + elapsed, updated_at: now),
    interval,
    capacity,
  )
}

fn fill(bank: Bank, interval: Int, capacity: Int) -> Bank {
  let cost = interval * { bank.credits + 1 }
  case bank.credits >= capacity {
    True -> Bank(..bank, progress_ms: 0)
    False if bank.progress_ms >= cost ->
      fill(
        Bank(
          ..bank,
          credits: bank.credits + 1,
          progress_ms: bank.progress_ms - cost,
        ),
        interval,
        capacity,
      )
    False -> bank
  }
}

pub fn ready_in(bank: Bank, now: Int, interval: Int) -> Int {
  int.max(int.max(0, bank.available_at - now), case bank.credits > 0 {
    True -> 0
    False -> int.max(0, interval - bank.progress_ms)
  })
}

pub fn recharge_in(bank: Bank, interval: Int, capacity: Int) -> Int {
  case bank.credits >= capacity {
    True -> 0
    False -> interval * { bank.credits + 1 } - bank.progress_ms
  }
}

pub fn spend(bank: Bank, now: Int, gap: Int) -> Bank {
  Bank(
    bank.credits - 1,
    bank.progress_ms * bank.credits / { bank.credits + 1 },
    now,
    now + gap,
  )
}
