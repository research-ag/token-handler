import CreditManager "CreditManager";
import { Data } "Data";
import ICRC1 "icrc1-api";

module {

  public type TokenHandler = {
    var isFrozen_ : Bool;
    ledger : Ledger;
    data : Data.Data<Principal>;
    feeManager : FeeManager;
    creditManager : CreditManager.CreditManager;
    depositManager : DepositManager;
    allowanceManager : AllowanceManager;
    withdrawalManager : WithdrawalManager;
    triggerOnNotifications : Bool;
    ownPrincipal : Principal;
    log : (Principal, LogEvent) -> ();
  };

  public type TokenHandlerContext = {
    api : ICRC1.API;
    assertInvariant : () -> Bool;
    onFeeChanged : (oldFee : Nat, newFee : Nat) -> ();
  };

  public type Ledger = {
    var ownPrincipal : Principal; // FIXME should not be mutable
    var fee : Nat;
    var feeLock : Bool;
  };

  public type AllowanceManager = {
    var totalCredited : Nat;
  };

  public type AllowanceManagerLogEvent = {
    #allowanceDrawn : {
      amount : Nat;
      credited : Nat;
      surcharge : Nat;
    };
  };

  public type DepositManager = {
    var paused : Bool;
    var totalConsolidated : Nat;
    var totalCredited : Nat;
    var underwayFunds : Nat;
  };

  public type DepositManagerLogEvent = {
    #newDeposit : {
      depositInc : Nat;
      creditInc : Nat;
      ledgerFee : Nat;
      surcharge : Nat;
    };
    #depositInc : Nat;
    #consolidated : {
      deducted : Nat;
      credited : Nat;
      fee : Nat;
    };
  };

  public type FeeManager = {
    var surcharge : Nat;
    var outstandingFees : Nat;
  };

  public type FeeManagerLogEvent = {
    #feeUpdated : { old : Nat; new : Nat; delta : Int };
    #surchargeUpdated : { old : Nat; new : Nat };
  };

  public type WithdrawalManager = {
    var totalWithdrawn : Nat;
    var lockedFunds : Nat;
  };

  public type WithdrawalManagerLogEvent = {
    #withdraw : {
      to : ICRC1.Account;
      amount : Nat;
      withdrawn : Nat;
      surcharge : Nat;
    };
    #locked : Int;
  };

  public type LogEvent = DepositManagerLogEvent or AllowanceManagerLogEvent or WithdrawalManagerLogEvent or CreditManager.LogEvent or FeeManagerLogEvent or {
    #error : Text;
  };
};
