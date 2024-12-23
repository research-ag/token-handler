import Principal "mo:base/Principal";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Data "Data";

module {
  public type LogEvent = {
    #feeUpdated : { old : Nat; new : Nat };
    #surchargeUpdated : { old : Nat; new : Nat };
  };

  public type StableData = {
    surcharge : Nat;
    outstandingFees : Nat;
  };

  public type State = {
    ledger : Nat;
    deposit : Nat;
    surcharge : Nat;
    outstandingFees : Nat;
  };

  public class FeeManager(
    ledger : {
      fee : () -> Nat;
      var onFeeChanged : (Nat, Nat) -> ();
    },
    data : Data.Data<Principal>,
    log : (Principal, LogEvent) -> (),
  ) {
    var surcharge_ = 0;

    var outstandingFees : Nat = 0;

    let oldCallback = ledger.onFeeChanged;
    ledger.onFeeChanged := func(old : Nat, new : Nat) {
      oldCallback(old, new);
      let delta = (new : Int - old) * data.depositsCount();
      data.changeHandlerPool(-delta);
      let sum = outstandingFees + delta;
      assert sum >= 0;
      outstandingFees := Int.abs(sum);
      log(Principal.fromBlob(""), #feeUpdated({ old; new }));
    };

    public func fee() : Nat = ledgerFee() + surcharge_;

    public func ledgerFee() : Nat = ledger.fee();

    public func surcharge() : Nat = surcharge_;

    public func setSurcharge(s : Nat) {
      log(Principal.fromBlob(""), #surchargeUpdated({ old = surcharge_; new = s }));
      surcharge_ := s;
    };

    public func addFee() {
      outstandingFees += ledgerFee();
    };

    public func state() : State = {
      ledger = ledgerFee();
      surcharge = surcharge();
      deposit = fee();
      outstandingFees;
    };

    public func share() : StableData = {
      surcharge = surcharge_;
      outstandingFees;
    };

    public func unshare(data : StableData) {
      surcharge_ := data.surcharge;
      outstandingFees := data.outstandingFees;
    };
  };
};
