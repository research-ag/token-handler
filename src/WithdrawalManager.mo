import Principal "mo:core/Principal";
import { type Result } "mo:core/Types";

import CreditManager "CreditManager";
import { Data; Entry } "Data";
import FeeManager "FeeManager";
import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";

module {

  public type State = {
    totalWithdrawn : Nat;
    lockedFunds : Nat;
  };

  public type WithdrawError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
    #TooLowQuantity;
    #InsufficientCredit;
  };

  public type WithdrawResponse = Result<(transactionIndex : Nat, withdrawnAmount : Nat), WithdrawError>;

  public type LogEvent = {
    #withdraw : {
      to : ICRC1.Account;
      amount : Nat;
      withdrawn : Nat;
      surcharge : Nat;
    };
    #locked : Int;
  };

  public type WithdrawalManager = {
    var totalWithdrawn : Nat;
    var lockedFunds : Nat;
  };

  public func new() : WithdrawalManager {
    {
      var totalWithdrawn = 0;
      var lockedFunds = 0;
    };
  };

  public func state(self : WithdrawalManager) : State = {
    totalWithdrawn = self.totalWithdrawn;
    lockedFunds = self.lockedFunds;
  };

  /// Initiates a withdrawal by transferring tokens to another account.
  /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
  /// creditAmount = amount of credit being deducted
  /// amount of tokens that the `to` account receives = creditAmount - userExpectedFee
  public func withdraw(
    self : WithdrawalManager,
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    creditManager : CreditManager.CreditManager,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    p : ?Principal,
    to : ICRC1.Account,
    creditAmount : Nat,
    userExpectedFee : ?Nat,
  ) : async* WithdrawResponse {
    let noPrincipal = Principal.fromBlob("");
    let realFee = switch (p) {
      case null feeManager.ledgerFee(icrc84); // withdrawal from pool
      case _ feeManager.fee(icrc84); // withdrawal from credit
    };
    switch (userExpectedFee) {
      case null {};
      case (?f) if (f != realFee) return #err(#BadFee { expected_fee = realFee });
    };
    if (creditAmount <= realFee) return #err(#TooLowQuantity);

    let (ok, principal) = switch (p) {
      case null (creditManager.burnPool(creditAmount), noPrincipal);
      case (?pp) (creditManager.burn(data, pp, creditAmount), pp);
    };
    if (ok) {
      self.lockedFunds += creditAmount;
      log(principal, #locked(creditAmount));
    } else {
      return #err(#InsufficientCredit);
    };

    let surcharge = feeManager.surcharge;

    let amountToSend = switch (p) {
      case (?_) creditAmount - surcharge : Nat;
      case null creditAmount;
    };

    let res = await* ICRC84Helper.send(icrc84, to, amountToSend);

    switch (res) {
      case (#ok txid) {
        switch (p) {
          case (?pp) {
            data.changeHandlerPool(surcharge);

            log(pp, #withdraw { to; amount = creditAmount; withdrawn = amountToSend; surcharge });
          };
          case null {
            log(noPrincipal, #withdraw { to; amount = creditAmount; withdrawn = creditAmount; surcharge = 0 });
          };
        };

        self.lockedFunds -= creditAmount;
        self.totalWithdrawn += amountToSend;

        #ok(txid, creditAmount - realFee : Nat);
      };
      case (#err(error)) {
        let realFee = switch (p) {
          case null feeManager.ledgerFee(icrc84);
          case _ feeManager.fee(icrc84);
        };
        let newError = switch (error) {
          case (#BadFee _) #BadFee { expected_fee = realFee };
          case _ error;
        };

        self.lockedFunds -= creditAmount;
        switch (p) {
          case (?pp) assert data.entry(pp).changeCredit(creditAmount);
          case null creditManager.changePool(creditAmount);
        };

        log(principal, #locked(-creditAmount));

        #err(newError);
      };
    };
  };
};
