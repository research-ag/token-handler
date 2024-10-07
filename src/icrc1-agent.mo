import ICRC1 "icrc1-api";
import R "mo:base/Result";

/// This module is built on top of icrc1-api.
/// It wraps the ICRC1 ledger API calls in try-catch blocks
/// and translates all async call errors into Error variants.
/// The purpose is that higher level code does not have to deal with try-catch blocks.
/// Higher level code can make calls to `async*` function that are guaranteed to never throw.
///
/// The module also tries to simplify making the calls.
/// It reduces generality by not allowing `memo` and `created_at_time` to be set.
/// They are always set to `null`.
/// It does not require the `fee` argument to be passed with every call.
/// Instead, `setFee()` can be called once and the provided fee value is then automatically passed along with every call made.
///
/// This module does not parse nor interpret any errors returned from calls.
/// In particular, it does not try to be smart about fees and does not try to auto-detect the ledger fee.
/// It does not deal with race conditions and concurrency issues between ledger calls.
///
/// This module is general-purpose. It is not specific to the TokenHandler.
module {
  public type TransferError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
  };

  public type TransferFromError = ICRC1.TransferFromError or {
    #CallIcrc1LedgerError;
  };

  public type TransferResult = R.Result<Nat, TransferError>;

  public type TransferFromResult = R.Result<Nat, TransferFromError>;

  public type BalanceResult = R.Result<Nat, { #CallIcrc1LedgerError }>;

  public type FeeResult = R.Result<Nat, { #CallIcrc1LedgerError }>;

  public class LedgerAgent(api : ICRC1.API) {
    var fee_ = 0;

    public func fee() : Nat = fee_;

    public func setFee(x : Nat) = fee_ := x;

    public func fetchFee() : async* FeeResult {
      try {
        #ok(await api.fee());
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

    public func balance_of(a : ICRC1.Account) : async* BalanceResult {
      try {
        #ok(await api.balance_of(a));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

    public func transfer(
      from_subaccount : ?ICRC1.Subaccount,
      to : ICRC1.Account,
      amount : Nat,
    ) : async* TransferResult {
      let args = {
        from_subaccount;
        to;
        amount;
        fee = ?fee_;
        memo = null;
        created_at_time = null;
      };
      try {
        R.fromUpper(await api.transfer(args));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

    public func transfer_from(
      from : ICRC1.Account,
      to : ICRC1.Account,
      amount : Nat,
      spender : ?ICRC1.Subaccount,
    ) : async* TransferFromResult {
      let args = {
        spender_subaccount = spender;
        from;
        to;
        amount;
        fee = ?fee_;
        memo = null;
        created_at_time = null;
      };
      try {
        R.fromUpper(await api.transfer_from(args));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };
  };
};
