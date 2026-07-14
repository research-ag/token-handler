import Principal "mo:core/Principal";

import { Data; Entry } "Data";

module {
  public type LogEvent = {
    #credited : Nat;
    #debited : Nat;
  };

  public type CreditManager = {
    var pool : Nat;
  };

  public func new() : CreditManager {
    {
      var pool = 0;
    };
  };

  public func poolBalance(self : CreditManager) : Nat = self.pool;

  // The creditUser/debitUser functions transfer credit from the
  // user to/from the pool.
  public func creditUser(
    self : CreditManager,
    data : Data.Data<Principal>,
    log : (Principal, LogEvent) -> (),
    p : Principal,
    amount : Nat,
  ) : Bool {
    if (amount > self.pool) return false;
    self.pool -= amount;

    let entry = data.entry(p);
    assert entry.changeCredit(amount);
    log(p, #credited(amount));
    true;
  };

  public func debitUser(
    self : CreditManager,
    data : Data.Data<Principal>,
    log : (Principal, LogEvent) -> (),
    p : Principal,
    amount : Nat,
  ) : Bool {
    let entry = data.entry(p);
    if (not entry.changeCredit(-amount)) return false;

    self.pool += amount;
    log(p, #debited(amount));
    true;
  };

  // Burn credit from a user or the pool
  // This is called on withdrawals
  // A check is performed, balances can not go negative
  public func burn(self : CreditManager, data : Data.Data<Principal>, p : Principal, amount : Nat) : Bool {
    ignore self;
    if (not data.entry(p).changeCredit(-amount)) return false;
    true;
  };

  public func changePool(self : CreditManager, amount : Nat) {
    self.pool += amount;
  };

  public func burnPool(self : CreditManager, amount : Nat) : Bool {
    if (amount > self.pool) return false;
    self.pool -= amount;
    true;
  };
};
