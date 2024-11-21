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
  public class CreditManager(data : Data.Data<Principal>, log : (Principal, LogEvent) -> ()) {
    /// Retrieves the total credited funds in the credit registry.
    public func totalBalance() : Nat = data.creditSum() + data.poolBalance();

    /// Gets the current credit amount associated with a specific principal.
    public func userBalance(p : Principal) : Int = data.get(p).credit();

    // The creditUser/debitUser functions transfer credit from the
    // user to/from the pool.
    public func creditUser(p : Principal, amount : Nat) : Bool {
      if (not data.changePool(-amount)) return false;

      let entry = data.get(p);
      assert entry.changeCredit(amount);
      log(p, #credited(amount));
      true;
    };

    public func debitUser(p : Principal, amount : Nat) : Bool {
      let entry = data.get(p);
      if (not entry.changeCredit(-amount)) return false;

      assert data.changePool(amount);
      log(p, #debited(amount));
      true;
    };

    // Burn credit from a user or the pool
    // This is called on withdrawals
    // A check is performed, balances can not go negative
    public func burn(p : Principal, amount : Nat) : Bool {
      if (not data.get(p).changeCredit(-amount)) return false;
      log(p, #burned(amount));
      true;
    };

    public func burnPool(amount : Nat) : Bool {
      if (not data.changePool(-amount)) return false;
      log(Principal.fromBlob(""), #burned(amount));
      true;
    };
  };
};
