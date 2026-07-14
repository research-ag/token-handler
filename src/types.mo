import { Data } "Data";
import ICRC1 "icrc1-api";

module {

  public type TokenHandler = {
    ownPrincipal : Principal;
    data : Data.Data<Principal>;
    depositManager : DepositManager;
    creditManager : CreditManager;
    feeManager : FeeManager;
    ledger : Ledger;
    withdrawalManager : WithdrawalManager;
    allowanceManager : AllowanceManager;
    var triggerOnNotifications : Bool;
  };

  public type TokenHandlerContext = {
    ownPrincipal : Principal;
    api : ICRC1.API;
    assertInvariant : () -> Bool;
    onFeeChanged : (oldFee : Nat, newFee : Nat) -> ();
    log : (Principal, LogEvent) -> ();
    var isFrozen_ : Bool;
  };

  public type Ledger = {
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

  public type CreditManager = {
    var pool : Nat;
  };

  public type CreditManagerLogEvent = {
    #credited : Nat;
    #debited : Nat;
  };

  public type LogEvent = DepositManagerLogEvent or AllowanceManagerLogEvent or WithdrawalManagerLogEvent or CreditManagerLogEvent or FeeManagerLogEvent or {
    #error : Text;
  };
};
