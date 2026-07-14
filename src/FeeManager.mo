import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";

import { Data } "Data";
import ICRC84Helper "icrc84-helper";
import Types "types";

module {
  public type LogEvent = Types.FeeManagerLogEvent;

  public type State = {
    ledger : Nat;
    deposit : Nat;
    surcharge : Nat;
    outstandingFees : Nat;
  };

  public type FeeManager = Types.FeeManager;

  public func new() : FeeManager {
    let self : FeeManager = {
      var surcharge = 0;
      var outstandingFees = 0;
    };
    self;
  };

  public func fee(self : FeeManager, ledger : ICRC84Helper.Ledger) : Nat = ledgerFee(self, ledger) + self.surcharge;

  public func ledgerFee(self : FeeManager, ledger : ICRC84Helper.Ledger) : Nat {
    ignore self;
    ICRC84Helper.fee(ledger);
  };

  public func setSurcharge(self : FeeManager, s : Nat, ctx : Types.TokenHandlerContext) {
    ctx.log(Principal.fromBlob(""), #surchargeUpdated({ old = self.surcharge; new = s }));
    self.surcharge := s;
  };

  public func addFee(self : FeeManager, ledger : ICRC84Helper.Ledger) {
    self.outstandingFees += ledgerFee(self, ledger);
  };

  public func subtractFee(self : FeeManager, fee : Nat) {
    self.outstandingFees -= fee;
  };

  public func state(self : FeeManager, ledger : ICRC84Helper.Ledger) : State = {
    ledger = ledgerFee(self, ledger);
    surcharge = self.surcharge;
    deposit = fee(self, ledger);
    outstandingFees = self.outstandingFees;
  };

  public func onFeeChanged(self : FeeManager, data : Data.Data<Principal>, old : Nat, new : Nat, ctx : Types.TokenHandlerContext) {
    let delta = (new : Int - old) * data.depositsCount();
    data.changeHandlerPool(-delta);
    let sum = (self.outstandingFees : Int) + delta;
    assert sum >= 0;
    self.outstandingFees := Int.abs(sum);
    ctx.log(Principal.fromBlob(""), #feeUpdated({ old; new; delta }));
  };
};
