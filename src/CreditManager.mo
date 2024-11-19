import Principal "mo:base/Principal";
import Int "mo:base/Int";
import Data "Data";

module {
  public type StableData = (Nat);

  public type LogEvent = {
    #credited : Nat;
    #debited : Nat;
    #burned : Nat;
  };

  /// Tracks credited funds (usable balance) associated with each principal.
  public class CreditManager(data : Data.Data, log : (Principal, LogEvent) -> ()) {
    let { map } = data;

    /// Retrieves the total credited funds in the credit registry.
    public func totalBalance() : Nat = map.creditSum() + data.pool;

    /// Retrieves the total credited funds in the pool.
    public func poolBalance() : Nat = data.pool;

    public func changePool(amount : Int) : Bool {
      let sum = data.pool + amount;
      if (sum < 0) return false;
      data.pool := Int.abs(sum);
      true;
    };

    /// Gets the current credit amount associated with a specific principal.
    public func userBalance(p : Principal) : Int = map.get(p).credit();

    // The creditUser/debitUser functions transfer credit from the
    // user to/from the pool.
    public func creditUser(p : Principal, amount : Nat) : Bool {
      if (not changePool(-amount)) return false;

      let entry = map.get(p);
      assert entry.changeCredit(amount);
      log(p, #credited(amount));
      true;
    };

    public func debitUser(p : Principal, amount : Nat) : Bool {
      let entry = map.get(p);
      if (not entry.changeCredit(-amount)) return false;

      assert changePool(amount);
      log(p, #debited(amount));
      true;
    };

    // Burn credit from a user or the pool
    // This is called on withdrawals
    // A check is performed, balances can not go negative
    public func burn(p : Principal, amount : Nat) : Bool {
      if (not map.get(p).changeCredit(-amount)) return false;
      log(p, #burned(amount));
      true;
    };

    public func burnPool(amount : Nat) : Bool {
      if (not changePool(-amount)) return false;
      log(Principal.fromBlob(""), #burned(amount));
      true;
    };

    /// Serializes the credit registry data.
    public func share() : StableData = data.pool;

    /// Deserializes the credit registry data.
    public func unshare(values : StableData) {
      data.pool := values;
    };
  };
};
