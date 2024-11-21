import Option "mo:base/Option";
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
  };

  public type WithdrawError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
    #TooLowQuantity;
    #InsufficientCredit;
  };

  type WithdrawResult = (transactionIndex : Nat, withdrawnAmount : Nat);

  public type WithdrawResponse = R.Result<WithdrawResult, WithdrawError>;

  public type LogEvent = {
    #withdraw : { to : ICRC1.Account; amount : Nat };
    #withdrawalError : WithdrawError;
    #issued : Int;
  };

  public class WithdrawalManager(
    ownPrincipal : Principal,
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    creditManager : CreditManager.CreditManager,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
  ) {
    var totalWithdrawn_ = 0;

    let noPrincipal = Principal.fromBlob("");

    public func totalWithdrawn() : Nat = totalWithdrawn_;

    // Without logging
    func process_withdraw(p : ?Principal, to : ICRC1.Account, creditAmount : Nat, userExpectedFee : ?Nat) : async* WithdrawResponse {
      let realFee = switch (p) {
        case null feeManager.ledgerFee(); // withdrawal from pool
        case _ feeManager.fee(); // withdrawal from credit
      };
      switch (userExpectedFee) {
        case null {};
        case (?f) if (f != realFee) return #err(#BadFee { expected_fee = realFee });
      };
      if (creditAmount <= realFee) return #err(#TooLowQuantity);

      let amountToSend : Nat = switch (p) {
        case null creditAmount;
        case (?p) creditAmount - feeManager.surcharge();
      };
      let surcharge_ = feeManager.surcharge();

      let res = await* icrc84.send(to, amountToSend);

      if (R.isOk(res)) {
        totalWithdrawn_ += amountToSend;
        if (p != null) {
          log(Principal.fromBlob(""), #issued(surcharge_));
          assert data.changePool(surcharge_);
        };
      };

      // return value
      switch (res) {
        case (#ok txid) #ok(txid, creditAmount - realFee); // = amount arrived
        case (#err(#BadFee _)) {
          #err(#BadFee { expected_fee = feeManager.fee() }); // return the expected fee value from now
        };
        case (#err err) #err(err);
      };
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    /// creditAmount = amount of credit being deducted
    /// amount of tokens that the `to` account receives = creditAmount - userExpectedFee
    public func withdraw(p : ?Principal, to : ICRC1.Account, creditAmount : Nat, userExpectedFee : ?Nat) : async* WithdrawResponse {
      let ok = switch (p) {
        case null creditManager.burnPool(creditAmount);
        case (?pp) creditManager.burn(pp, creditAmount);
      };
      if (not ok) {
        let err = #InsufficientCredit;
        log(ownPrincipal, #withdrawalError(err));
        return #err(err);
      };
      let res = await* process_withdraw(p, to, creditAmount, userExpectedFee);

      // logging
      let event = switch (res) {
        case (#ok _) #withdraw({ to = to; amount = creditAmount });
        case (#err err) #withdrawalError(err);
      };

      log(Option.get(p, noPrincipal), event);
      if (R.isErr(res)) {
        // re-issue credit if unsuccessful
        switch (p) {
          case null {
            assert data.changePool(creditAmount);
            log(Principal.fromBlob(""), #issued(creditAmount));
          };
          case (?pp) {
            assert data.get(pp).changeCredit(creditAmount);
            log(pp, #issued(creditAmount));
          };
        };
      };
      res;
    };

    public func share() : StableData = {
      totalWithdrawn = totalWithdrawn_;
    };

    public func unshare(data : StableData) {
      totalWithdrawn_ := data.totalWithdrawn;
    };
  };
};
