import Principal "mo:base/Principal";

module {
  public type LogEvent = {
    #feeUpdated : { old : Nat; new : Nat };
    #surchargeUpdated : { old : Nat; new : Nat };
  };

  public type StableData = {
    surcharge : Nat;
  };

  public type State = {
    ledger : Nat;
    deposit : Nat;
    surcharge : Nat;
  };

  public class FeeManager(
    ledger : {
      fee : () -> Nat;
      var onFeeChanged : (Nat, Nat) -> ();
    },
    log : (Principal, LogEvent) -> (),
  ) {
    var surcharge_ = 0;

    let oldCallback = ledger.onFeeChanged;
    ledger.onFeeChanged := func(old : Nat, new : Nat) {
      oldCallback(old, new);
      log(Principal.fromBlob(""), #feeUpdated({ old; new }));
    };

    public func fee() : Nat = ledgerFee() + surcharge_;

    public func ledgerFee() : Nat = ledger.fee();

    public func surcharge() : Nat = surcharge_;

    public func setSurcharge(s : Nat) {
      log(Principal.fromBlob(""), #surchargeUpdated({ old = surcharge_; new = s }));
      surcharge_ := s;
    };

    public func state() : State = {
      ledger = ledgerFee();
      surcharge = surcharge();
      deposit = fee();
    };

    public func share() : StableData = {
      surcharge = surcharge_;
    };

    public func unshare(data : StableData) {
      surcharge_ := data.surcharge;
    };
  };
};
