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

import Util "util";
import ICRC1 "ICRC1";
import AccountManager "AccountManager";
import CreditRegistry "CreditRegistry";

module {
  public type StableData = (
    AccountManager.StableData, // account manager
    CreditRegistry.StableData, // credit registry
  );

  public type LogEvent = AccountManager.LogEvent or CreditRegistry.LogEvent or {
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

  /// Returns default stable data for `TokenHandler`.
  public func defaultStableData() : StableData = (((#leaf, 0, 0, 1), 0, 0, 0, 0, 0, 0, 0, 0, 0), ([], 0));

  /// Converts `Principal` to `ICRC1.Subaccount`.
  public func toSubaccount(p : Principal) : ICRC1.Subaccount = Util.toSubaccount(p);

  /// Converts `ICRC1.Subaccount` to `Principal`.
  public func toPrincipal(subaccount : ICRC1.Subaccount) : ?Principal = Util.toPrincipal(subaccount);

  public type ICRC1Ledger = ICRC1.ICRC1Ledger;

  public type LedgerAPI = ICRC1.LedgerAPI;

  /// Build a `LedgerAPI` object based on the ledger principal.
  public func buildLedgerApi(ledgerPrincipal : Principal) : LedgerAPI {
    (actor (Principal.toText(ledgerPrincipal)) : ICRC1Ledger)
    |> {
      balance_of = _.icrc1_balance_of;
      fee = _.icrc1_fee;
      transfer = _.icrc1_transfer;
      transfer_from = _.icrc2_transfer_from;
    };
  };

  /// Class `TokenHandler` provides mechanisms to facilitate the deposit and withdrawal management on an ICRC-1 ledger.
  ///
  /// Key features include subaccount management, deposit notifications, credit registry, and withdrawal mechanisms,
  /// providing a comprehensive solution for handling ICRC-1 token transactions.
  public class TokenHandler({ ledgerApi; ownPrincipal; initialFee; triggerOnNotifications; log } : TokenHandlerOptions) {

    /// Returns `true` when new notifications are paused.
    public func notificationsOnPause() : Bool = accountManager.notificationsOnPause();

    /// Pause new notifications.
    public func pauseNotifications() = accountManager.pauseNotifications();

    /// Unpause new notifications.
    public func unpauseNotifications() = accountManager.unpauseNotifications();

    // Pass through the lookup counter from depositRegistry
    // TODO: Remove later
    public func lookups_() : Nat = accountManager.lookups();

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

    /// Manages accounts and funds for users.
    /// Handles deposit, withdrawal, and consolidation operations.
    let accountManager = AccountManager.AccountManager(
      ledgerApi,
      ownPrincipal,
      log,
      initialFee,
      triggerOnNotifications,
      freezeTokenHandler,
      func(p : Principal, x : Int) { creditRegistry.issue(#user p, x) },
    );

    /// Returns the ledger fee.
    public func ledgerFee() : Nat = accountManager.ledgerFee();

    /// Retrieves the admin-defined fee of the specific type.
    public func definedFee(t : AccountManager.FeeType) : Nat = accountManager.definedFee(t);

    /// Calculates the final fee of the specific type.
    public func fee(t : AccountManager.FeeType) : Nat = accountManager.fee(t);

    /// Defines the admin-defined fee of the specific type.
    public func setFee(t : AccountManager.FeeType, value : Nat) = accountManager.setFee(t, value);

    /// Retrieves the admin-defined minimum of the specific type.
    public func definedMinimum(minimumType : AccountManager.MinimumType) : Nat = accountManager.definedMinimum(minimumType);

    /// Calculates the final minimum of the specific type.
    public func minimum(minimumType : AccountManager.MinimumType) : Nat = accountManager.minimum(minimumType);

    /// Defines the admin-defined minimum of the specific type.
    public func setMinimum(minimumType : AccountManager.MinimumType, min : Nat) = accountManager.setMinimum(minimumType, min);

    /// Fetches and updates the fee from the ICRC1 ledger.
    /// Returns the new fee, or `null` if fetching is already in progress.
    public func fetchFee() : async* ?Nat {
      await* accountManager.fetchFee();
    };

    /// Returns a user's last know (= tracked) deposit
    /// Null means the principal is locked, hence no value is available.
    public func trackedDeposit(p : Principal) : ?Nat = accountManager.getDeposit(p);

    /// Returns the current `TokenHandler` state.
    public func state() : {
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
    } = {
      balance = {
        deposited = accountManager.depositedFunds();
        underway = accountManager.underwayFunds();
        queued = accountManager.queuedFunds();
        consolidated = accountManager.consolidatedFunds();
      };
      flow = {
        consolidated = accountManager.totalConsolidated();
        withdrawn = accountManager.totalWithdrawn();
      };
      credit = {
        total = creditRegistry.totalBalance();
        pool = creditRegistry.poolBalance();
      };
      users = {
        queued = accountManager.depositsNumber();
      };
    };

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
    /// let (depositDelta, credit) = await* notify(userPrincipal);
    /// ```
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      if isFrozen_ return null;
      let ?result = await* accountManager.notify(p) else return null;
      ?result;
    };

    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    ///
    /// Example:
    /// ```motoko
    /// // Set up an allowance on the user's account and then call depositFromAllowance
    /// let userPrincipal = ...; // The principal of the user making the deposit
    /// let userAccount = { owner = userPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to deposit
    ///
    /// let response = await* handler.depositFromAllowance(userAccount, amount);
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
    public func depositFromAllowance(p : Principal, account : ICRC1.Account, amount : Nat) : async* AccountManager.DepositFromAllowanceResponse {
      await* accountManager.depositFromAllowance(p, account, amount);
    };

    /// Triggers the proccessing deposits.
    /// n - desired number of potential consolidations.
    ///
    /// Example:
    /// ```motoko
    /// await* handler.trigger(1); // trigger 1 potential consolidation
    /// await* handler.trigger(10); // trigger 10 potential consolidation
    /// ```
    public func trigger(n : Nat) : async* () {
      if isFrozen_ return;
      await* accountManager.trigger(n);
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    ///
    /// Example:
    /// ```motoko
    /// let recipientAccount = { owner = recipientPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to withdraw
    ///
    /// let response = await* tokenHandler.withdrawFromCredit(recipientAccount, amount);
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
    public func withdrawFromPool(to : ICRC1.Account, amount : Nat) : async* AccountManager.WithdrawResponse {
      // try to burn from pool
      let success = creditRegistry.burn(#pool, amount);
      if (not success) return #err(#InsufficientCredit);
      let result = await* accountManager.withdraw(to, amount);
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
    /// Example:
    /// ```motoko
    /// let userPrincipal = ...; // The principal of the user transferring tokens
    /// let recipientAccount = { owner = recipientPrincipal; subaccount = ?subaccountBlob };
    /// let amount: Nat = 100_000; // Amount to withdraw
    ///
    /// let response = await* tokenHandler.withdrawFromCredit(userPrincipal, recipientAccount, amount);
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
    public func withdrawFromCredit(p : Principal, to : ICRC1.Account, amount : Nat) : async* AccountManager.WithdrawResponse {
      // try to burn from user
      creditRegistry.burn(#user p, amount)
      |> (
        if (not _) {
          let err = #InsufficientCredit;
          log(ownPrincipal, #withdrawalError(err));
          return #err(err);
        }
      );
      let result = await* accountManager.withdraw(to, amount);
      if (Result.isErr(result)) {
        // re-issue credit if unsuccessful
        creditRegistry.issue(#user p, amount);
      };
      result;
    };

    /// For testing purposes.
    public func assertIntegrity() { accountManager.assertIntegrity() };

    /// Serializes the token handler data.
    public func share() : StableData = (
      accountManager.share(),
      creditRegistry.share(),
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      accountManager.unshare(values.0);
      creditRegistry.unshare(values.1);
    };
  };

};
