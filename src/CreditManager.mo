import Principal "mo:base/Principal";
import Data "Data";

module {
  public type LogEvent = {
    #credited : Nat;
    #debited : Nat;
    #burned : Nat;
    #issued : Nat;
  };

  public type StableData = {
    pool : Nat;
  };

  /// Tracks credited funds (usable balance) associated with each principal.
  public class CreditManager(data : Data.Data<Principal>, log : (Principal, LogEvent) -> ()) {
    var pool = 0;

    public func poolBalance() : Nat = pool;

    // The creditUser/debitUser functions transfer credit from the
    // user to/from the pool.
    public func creditUser(p : Principal, amount : Nat) : Bool {
      if (amount > pool) return false;
      pool -= amount;

      let entry = data.get(p);
      assert entry.changeCredit(amount);
      log(p, #credited(amount));
      true;
    };

    public func debitUser(p : Principal, amount : Nat) : Bool {
      let entry = data.get(p);
      if (not entry.changeCredit(-amount)) return false;

      pool += amount;
      log(p, #debited(amount));
      true;
    };

    // Burn credit from a user or the pool
    // This is called on withdrawals
    // A check is performed, balances can not go negative
    public func burn(p : Principal, amount : Nat) : Bool {
      if (not data.get(p).changeCredit(-amount)) return false;
      true;
    };

    public func changePool(amount : Nat) {
      pool += amount;
      log(Principal.fromBlob(""), #issued(amount));
    };

    public func burnPool(amount : Nat) : Bool {
      if (amount > pool) return false;
      pool -= amount;
      true;
    };

    public func share() : StableData = { pool = pool };

    public func unshare(data : StableData) = pool := data.pool;
  };
};
