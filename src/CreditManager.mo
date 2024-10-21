import Principal "mo:base/Principal";
import Int "mo:base/Int";
import Data "Data";

module {
  public type StableData = (Nat);

  public type LogEvent = {
    #credited : Nat;
    #debited : Nat;
    #issued : Int;
    #burned : Nat;
  };

  /// Tracks credited funds (usable balance) associated with each principal.
  public class CreditManager(map : Data.Map<Principal>, log : (Principal, LogEvent) -> ()) {
    var pool_ = 0;

    /// Retrieves the total credited funds in the credit registry.
    public func totalBalance() : Nat = map.creditSum() + pool_;

    /// Retrieves the total credited funds in the pool.
    public func poolBalance() : Nat = pool_;

    public func changePool(amount : Int) : Bool {
      let sum = pool_ + amount;
      if (sum < 0) return false;
      pool_ := Int.abs(sum);
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
    public func share() : StableData = pool_;

    /// Deserializes the credit registry data.
    public func unshare(values : StableData) {
      pool_ := values;
    };
  };
};
