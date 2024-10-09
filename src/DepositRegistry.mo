import Principal "mo:base/Principal";
import NatMap "NatMapWithLock";
import Data "Data";

module {
  public type StableData = (NatMap.StableData<Principal>, Nat);

  // TODO: remove this type later
  public type StableDataMap = NatMap.StableData<Principal>;

  // DepositRegistry tracks the deposit fee and the deposits for each principal
  //
  // The fee argument is the initial deposit fee (aka forwarding fee or consolidation fee).
  // This class does not know about the individual components that make up the deposit fee.
  // In practice, the deposit fee will consist of the ledger fee and a surcharge.
  public class DepositRegistry(data : Data.Data, trap : Text -> ()) {
    let { map; queue; } = data;

    public func obtainLock(p : Principal) : ?Data.Entry<Principal> {
      null;
    };

    public func release(entry : Data.Entry<Principal>, deposit : Nat) {
      // let prev = entry.setDeposit(deposit);
      // if (prev > deposit) {

      // }
      // if (prev == 0) {
      //   queue.push(entry);
      // };
      // assert entry.unlock();
    };

    public func unlock(entry : Data.Entry<Principal>) = assert entry.unlock();
  };
};
