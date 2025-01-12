import Principal "mo:base/Principal";
import R "mo:base/Result";
import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";
import FeeManager "FeeManager";
import CreditManager "CreditManager";
import Data "Data";

module {
  public type StableData = {
    totalWithdrawn : Nat;
    lockedFunds : Nat;
  };

  public type State = {
    totalWithdrawn : Nat;
    lockedFunds : Nat;
  };

  public type WithdrawError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
    #TooLowQuantity;
    #InsufficientCredit;
  };

  public type WithdrawResponse = R.Result<(transactionIndex : Nat, withdrawnAmount : Nat), WithdrawError>;

  public type LogEvent = {
    #withdraw : {
      to : ICRC1.Account;
      amount : Nat;
      withdrawn : Nat;
      surcharge : Nat;
    };
    #locked : Nat;
  };

  public class WithdrawalManager(
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    creditManager : CreditManager.CreditManager,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
  ) {
    var totalWithdrawn = 0;
    var lockedFunds = 0;

    let noPrincipal = Principal.fromBlob("");

    public func state() : State = {
      totalWithdrawn;
      lockedFunds;
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    /// creditAmount = amount of credit being deducted
    /// amount of tokens that the `to` account receives = creditAmount - userExpectedFee
    public func withdraw(p : ?Principal, to : ICRC1.Account, creditAmount : Nat, userExpectedFee : ?Nat) : async* WithdrawResponse {
      let realFee = switch (p) {
        case null feeManager.ledgerFee(); // withdrawal from pool
        case _ feeManager.fee(); // withdrawal from credit
      };
      switch (userExpectedFee) {
        case null {};
        case (?f) if (f != realFee) return #err(#BadFee { expected_fee = realFee });
      };
      if (creditAmount <= realFee) return #err(#TooLowQuantity);

      let (ok, principal) = switch (p) {
        case null (creditManager.burnPool(creditAmount), noPrincipal);
        case (?pp) (creditManager.burn(pp, creditAmount), pp);
      };
      if (ok) {
        lockedFunds += creditAmount;
        log(principal, #locked(creditAmount));
      } else {
        return #err(#InsufficientCredit);
      };

      let surcharge = feeManager.surcharge();

      let amountToSend = switch (p) {
        case (?_) creditAmount - surcharge : Nat;
        case null creditAmount;
      };

      let res = await* icrc84.send(to, amountToSend);

      let result = switch (res) {
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

          lockedFunds -= creditAmount;
          totalWithdrawn += amountToSend;

          #ok(txid, creditAmount - realFee : Nat);
        };
        case (#err(error)) {
          let realFee = switch (p) {
            case null feeManager.ledgerFee();
            case _ feeManager.fee();
          };
          let newError = switch (error) {
            case (#BadFee _) #BadFee { expected_fee = realFee };
            case _ error;
          };

          #err(newError);
        };
      };

      result;
    };

    public func share() : StableData = {
      totalWithdrawn;
      lockedFunds;
    };

    public func unshare(data : StableData) {
      totalWithdrawn := data.totalWithdrawn;
      lockedFunds := data.lockedFunds;
    };
  };
};
