import Option "mo:base/Option";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";

module {
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
  };

  public class WithdrawalManager(
    icrc84 : ICRC84Helper.Ledger,
    surcharge : () -> Nat,
    changeCredit : ({ #pool; #user : Principal }, Int) -> (),
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
  ) {
    func fee() : Nat = icrc84.fee() + surcharge();
    var totalWithdrawn_ = 0;
    let noPrincipal = Principal.fromBlob("");

    public func totalWithdrawn() : Nat = totalWithdrawn_;

    /// Object to track all credit flows initiated from within DepositManager.
    /// The flow should never become negative.
    let credit = object {
      public var flow : Int = 0;
      public func change(who : { #user : Principal; #pool }, amount : Int) {
        changeCredit(who, amount);
        flow += amount;
        if (flow < 0) trap("credit flow went negative");
      };
    };

    // Without logging
    func process_withdraw(p : ?Principal, to : ICRC1.Account, creditAmount : Nat, userExpectedFee : ?Nat) : async* WithdrawResponse {
      let realFee = switch (p) {
        case (null) icrc84.fee(); // withdrawal from pool
        case (_) fee(); // withdrawal from credit
      };
      switch (userExpectedFee) {
        case (null) {};
        case (?f) if (f != realFee) return #err(#BadFee { expected_fee = realFee });
      };
      if (creditAmount <= realFee) return #err(#TooLowQuantity);

      let amountToSend : Nat = switch (p) {
        case (null) creditAmount;
        case (?p) creditAmount - surcharge();
      };
      let surcharge_ = surcharge();

      let res = await* icrc84.send(to, amountToSend);

      if (R.isOk(res)) {
        totalWithdrawn_ += amountToSend;
        if (p != null) credit.change(#pool, surcharge_);
      };

      // return value
      switch (res) {
        case (#ok txid) #ok(txid, creditAmount - realFee); // = amount arrived
        case (#err(#BadFee _)) {
          #err(#BadFee { expected_fee = fee() }); // return the expected fee value from now
        };
        case (#err err) #err(err);
      };
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    /// creditAmount = amount of credit being deducted
    /// amount of tokens that the `to` account receives = creditAmount - userExpectedFee
    public func withdraw(p : ?Principal, to : ICRC1.Account, creditAmount : Nat, userExpectedFee : ?Nat) : async* WithdrawResponse {
      let res = await* process_withdraw(p, to, creditAmount, userExpectedFee);

      // logging
      let event = switch (res) {
        case (#ok _) #withdraw({ to = to; amount = creditAmount });
        case (#err err) #withdrawalError(err);
      };

      log(Option.get(p, noPrincipal), event);

      res
    };

  };
};
