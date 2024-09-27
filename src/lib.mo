/// TokenHandler
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Timo Hanke (timohanke)
/// Contributors: Denys Kushnarov (reginleif888), Andy Gura (AndyGura)

import Principal "mo:base/Principal";
import Int "mo:base/Int";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Result "mo:base/Result";

import ICRC84 "mo:icrc84";
import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";
//import AccountManager "AccountManager";
import DepositManager "DepositManager";
import AllowanceManager "AllowanceManager";
import WithdrawalManager "WithdrawalManager";
import CreditRegistry "CreditRegistry";

module {
  public type StableData = (
    DepositManager.StableData, // account manager
    CreditRegistry.StableData, // credit registry
  );

  public type LogEvent = DepositManager.LogEvent or AllowanceManager.LogEvent or WithdrawalManager.LogEvent or CreditRegistry.LogEvent or {
    #error : Text;
  };

  public type AccountInfo = {
    deposit : Nat;
    credit : Int;
  };

  public type TokenHandlerOptions = {
    ledgerApi : LedgerAPI;
    ownPrincipal : Principal;
    initialFee : Nat;
    triggerOnNotifications : Bool;
    log : (Principal, LogEvent) -> ();
  };

  public type State = {
    balance : {
      deposited : Nat;
      underway : Nat;
      queued : Nat;
      consolidated : Nat;
    };
    flow : {
      consolidated : Nat;
      withdrawn : Nat;
    };
    credit : {
      total : Int;
      pool : Int;
    };
    users : {
      queued : Nat;
    };
    depositManager : DepositManager.State;
  };

  /// Returns default stable data for `TokenHandler`.
  public func defaultStableData() : StableData = ((((#leaf, 0, 0, 1), 0), 0), ([], 0, 0));
  //public func defaultStableData() : StableData = (([], 0, 0));

  /// Converts `Principal` to `ICRC1.Subaccount`.
  public func toSubaccount(p : Principal) : ICRC1.Subaccount = ICRC84.toSubaccount(p);

  /// Converts `ICRC1.Subaccount` to `Principal`.
  public func toPrincipal(subaccount : ICRC1.Subaccount) : ?Principal = ICRC84.toPrincipal(subaccount);

  public type LedgerAPI = ICRC1.API;

  /// Build a `LedgerAPI` object based on the ledger principal.
  public func buildLedgerApi(ledgerPrincipal : Principal) : LedgerAPI {
    ledgerPrincipal
    |> ICRC1.service(_)
    |> ICRC1.apiFromService(_);
  };

  /// Class `TokenHandler` provides mechanisms to facilitate the deposit and withdrawal management on an ICRC-1 ledger.
  ///
  /// Key features include subaccount management, deposit notifications, credit registry, and withdrawal mechanisms,
  /// providing a comprehensive solution for handling ICRC-1 token transactions.
  public class TokenHandler({ ledgerApi; ownPrincipal; initialFee; triggerOnNotifications; log } : TokenHandlerOptions) {

    /// Returns `true` when new notifications are paused.
    public func notificationsOnPause() : Bool = depositManager.state().paused;

    /// Pause new notifications.
    public func pauseNotifications() = depositManager.pause(true);

    /// Unpause new notifications.
    public func unpauseNotifications() = depositManager.pause(false);

    /// If some unexpected error happened, this flag turns true and handler stops doing anything until recreated.
    var isFrozen_ : Bool = false;

    /// Checks if the TokenHandler is frozen.
    public func isFrozen() : Bool = isFrozen_;

    /// Freezes the handler in case of unexpected errors and logs the error message to the journal.
    func freezeTokenHandler(errorText : Text) : () {
      isFrozen_ := true;
      log(ownPrincipal, #error(errorText));
    };

    /// Tracks credited funds (usable balance) associated with each principal.
    let creditRegistry = CreditRegistry.CreditRegistry(log);

    let Ledger = ICRC84Helper.Ledger(ledgerApi, ownPrincipal, initialFee);

    let depositManager = DepositManager.DepositManager(
      Ledger,
      triggerOnNotifications,
      creditRegistry.issue,
      log,
      freezeTokenHandler
    );

    Ledger.callback := func(oldFee : Nat, newFee : Nat) {
      depositManager.registerFeeChange(oldFee, newFee);
    };

    /// Returns the ledger fee.
    public func ledgerFee() : Nat = depositManager.state().fee.ledger;

    /// Returns the current surcharge amount.
    public func surcharge() : Nat = depositManager.state().fee.surcharge;

    /// Sets new surcharge amount.
    public func setSurcharge(s : Nat) = depositManager.setSurcharge(s);

    /// Calculates the final fee of the specific type.
    public func fee(_ : { #deposit; #allowance; #withdrawal }) : Nat = depositManager.state().fee.deposit;

    /// Fetches and updates the fee from the ICRC1 ledger.
    /// Returns the new fee, or `null` if fetching is already in progress.
    public func fetchFee() : async* ?Nat {
      await* Ledger.loadFee();
    };

    /// Returns a user's last know (= tracked) deposit
    /// Null means the principal is locked, hence no value is available.
    public func trackedDeposit(p : Principal) : ?Nat = depositManager.getDeposit(p);

    let allowanceManager = AllowanceManager.AllowanceManager(
      Ledger,
      surcharge, // surcharge
      creditRegistry.issue,
      log,
      freezeTokenHandler
    );

    let withdrawalManager = WithdrawalManager.WithdrawalManager(
      Ledger,
      surcharge, // surcharge
      creditRegistry.issue,
      log,
      freezeTokenHandler
    );

    /// Returns the current `TokenHandler` state.
    public func state() : State = ( 
      depositManager.state() |> {
      balance = {
        deposited = _.funds.deposited;
        underway = _.funds.underway;
        queued = _.funds.queued;
        consolidated = _.totalConsolidated - withdrawalManager.totalWithdrawn();
      };
      flow = {
        consolidated = _.totalConsolidated;
        withdrawn = withdrawalManager.totalWithdrawn();
      };
      credit = {
        total = creditRegistry.totalBalance();
        pool = creditRegistry.poolBalance();
      };
      users = {
        queued = _.nDeposits;
        locked = _.nLocks;
      };
      depositManager = depositManager.state();
//      withdrawalManager = withdrawalManager.state();
//      allowanceManager = allowanceManager.state();
    });

    /// Gets the current credit amount associated with a specific principal.
    public func userCredit(p : Principal) : Int = creditRegistry.userBalance(p);

    /// Gets the current credit amount in the pool.
    public func poolCredit() : Int = creditRegistry.poolBalance();

    /// Adds amount to P’s credit.
    /// With checking the availability of sufficient funds.
    ///
    /// Example:
    /// ```motoko
    /// let userPrincipal = ...;
    /// let amount: Nat = 100_000; // Amount to credit
    /// let success = creditUser(userPrincipal, amount);
    /// if (success) {
    ///   // Handle success
    /// } else {
    ///   // Handle fail
    /// };
    /// ```
    public func creditUser(p : Principal, amount : Nat) : Bool = creditRegistry.creditUser(p, amount);

    /// Deducts amount from P’s credit.
    /// With checking the availability of sufficient funds in the pool.
    ///
    /// Example:
    /// ```motoko
    /// let userPrincipal = ...;
    /// let amount: Nat = 100_000; // Amount to debit
    /// let success = debitUser(userPrincipal, amount);
    /// if (success) {
    ///   // Handle success
    /// } else {
    ///   // Handle fail
    /// };
    /// ```
    public func debitUser(p : Principal, amount : Nat) : Bool = creditRegistry.debitUser(p, amount);

    /// For debug and testing purposes only.
    /// Issue credit directly to a principal or burn from a principal.
    /// A negative amount means burn.
    /// Without checking the availability of sufficient funds.
    public func issue_(account : CreditRegistry.Account, amount : Int) = creditRegistry.issue(account, amount);

    /// Notifies of a deposit and schedules consolidation process.
    /// Returns the newly detected deposit and credit funds if successful, otherwise `null`.
    ///
    /// Example:
    /// ```motoko
    /// let userPrincipal = ...; // The principal of the user making the deposit
    /// let (depositDelta, creditDelta) = await* notify(userPrincipal);
    /// ```
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      if isFrozen_ return null;
      let ?result = await* depositManager.notify(p) else return null;
      ?result;
    };

    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    /// `amount` = credit-side amount.
    ///
    /// Example:
    /// ```motoko
    /// // Set up an allowance on the user's account and then call depositFromAllowance
    /// let userPrincipal = ...; // The principal of the user making the deposit
    /// let userAccount = { owner = userPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to deposit
    /// let allowanceFee : Nat = ... // Current allowance fee
    ///
    /// let response = await* handler.depositFromAllowance(userPrincipal, userAccount, amount, allowanceFee);
    /// switch (response) {
    ///   case (#ok credit_inc) {
    ///     // Handle successful deposit
    ///   };
    ///   case (#err err) {
    ///     // Handle error cases
    ///     switch (err) {
    ///       case (#CallIcrc1LedgerError) { ... };
    ///       ...
    ///     }
    ///   };
    /// };
    /// ```
    public func depositFromAllowance(p : Principal, source : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* AllowanceManager.DepositFromAllowanceResponse {
      await* allowanceManager.depositFromAllowance(p, source, amount, expectedFee);
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    ///
    /// Example:
    /// ```motoko
    /// await* handler.trigger(1); // trigger 1 potential consolidation
    /// await* handler.trigger(10); // trigger 10 potential consolidation
    /// ```
    public func trigger(n : Nat) : async* () {
      if isFrozen_ return;
      await* depositManager.trigger(n);
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    /// At the same time, it reduces the pool credit. Accordingly, amount <= credit should be satisfied.
    ///
    /// Example:
    /// ```motoko
    /// let recipientAccount = { owner = recipientPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to withdraw
    /// let withdrawalFee : Nat = ... // Current withdrawal fee
    ///
    /// let response = await* tokenHandler.withdrawFromCredit(recipientAccount, amount, withdrawalFee);
    /// switch(response) {
    ///   case (#ok (transactionIndex, withdrawnAmount)) {
    ///     // Handle successful withdrawal
    ///   };
    ///   case (#err err) {
    ///     // Handle error cases
    ///     switch (err) {
    ///       case (#CallIcrc1LedgerError) { ... };
    ///       ...
    ///     }
    ///   };
    /// ```
    public func withdrawFromPool(to : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* WithdrawalManager.WithdrawResponse {
      // try to burn from pool
      creditRegistry.burn(#pool, amount) 
      |> (
        if (not _) {
          let err = #InsufficientCredit;
          log(ownPrincipal, #withdrawalError(err));
          return #err(err);
        }
      );
      let result = await* withdrawalManager.withdraw(null, to, amount, expectedFee);
      if (Result.isErr(result)) {
        // re-issue credit if unsuccessful
        creditRegistry.issue(#pool, amount);
      };
      result;
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    /// At the same time, it reduces the user's credit. Accordingly, amount <= credit should be satisfied.
    ///
    /// creditAmount = amount of credit being deducted
    /// amount of tokens that the `to` account receives = creditAmount - userExpectedFee
    ///
    /// Example:
    /// ```motoko
    /// let userPrincipal = ...; // The principal of the user transferring tokens
    /// let recipientAccount = { owner = recipientPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to withdraw
    /// let withdrawalFee : Nat = ... // Current withdrawal fee
    ///
    /// let response = await* tokenHandler.withdrawFromCredit(userPrincipal, recipientAccount, amount, withdrawalFee);
    /// switch(response) {
    ///   case (#ok (transactionIndex, withdrawnAmount)) {
    ///     // Handle successful withdrawal
    ///   };
    ///   case (#err err) {
    ///     // Handle error cases
    ///     switch (err) {
    ///       case (#CallIcrc1LedgerError) { ... };
    ///       ...
    ///     }
    ///   };
    /// ```
    public func withdrawFromCredit(p : Principal, to : ICRC1.Account, creditAmount : Nat, expectedFee : ?Nat) : async* WithdrawalManager.WithdrawResponse {
      // try to burn from user
      creditRegistry.burn(#user p, creditAmount)
      |> (
        if (not _) { 
          let err = #InsufficientCredit;
          log(ownPrincipal, #withdrawalError(err));
          return #err(err);
        }
      );
      let result = await* withdrawalManager.withdraw(?p, to, creditAmount, expectedFee);
      if (Result.isErr(result)) {
        // re-issue credit if unsuccessful
        creditRegistry.issue(#user p, creditAmount);
      };
      result;
    };

    /// For testing purposes.
    //public func assertIntegrity() { accountManager.assertIntegrity() };
    public func assertIntegrity() {};

    /// Serializes the token handler data.
    public func share() : StableData = (
      depositManager.share(),
      creditRegistry.share(),
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      depositManager.unshare(values.0);
      creditRegistry.unshare(values.1);
    };
  };
};
