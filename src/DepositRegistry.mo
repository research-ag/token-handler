import Principal "mo:base/Principal";
import NatMap "NatMapWithLock";

module {
  public type StableData = (NatMap.StableData<Principal>, Nat);

  // TODO: remove this type later
  public type StableDataMap = NatMap.StableData<Principal>;

  // DepositRegistry tracks the deposit fee and the deposits for each principal
  //
  // The fee argument is the initial deposit fee (aka forwarding fee or consolidation fee).
  // This class does not know about the individual components that make up the deposit fee.
  // In practice, the deposit fee will consist of the ledger fee and a surcharge.
  public class DepositRegistry(fee_ : Nat, trap : Text -> ()) {
    public var fee : Nat = fee_;

    public let map = NatMap.NatMapWithLock<Principal>(
      Principal.compare,
      fee + 1,
    );

    public func updateFee(
      newFee : Nat,
      changeBy : (Principal, Int) -> (), // callback for changed deposit values
    ) {
      let oldFee = fee;
      fee := newFee;
      // update the deposit minimum depending on the new fee
      // the callback reports the principal for deposits that are removed in this step
      map.setMinimum(newFee + 1, func(p, v) = changeBy(p, oldFee - v));
      // report adjusted values for all queued deposits
      map.iterate(
        func(p, v) {
          if (v <= newFee) trap("deposit <= newFee should have been erased in previous step");
          changeBy(p, oldFee - newFee);
        }
      );
    };

    public func share() : StableData = (map.share(), fee);

    public func unshare(values : StableData) {
      map.unshare(values.0);
      fee := values.1;
    };
  };
};
