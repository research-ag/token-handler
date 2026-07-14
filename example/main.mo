import Array "mo:core/Array";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Timer "mo:core/Timer";
import Time "mo:core/Time";
import Blob "mo:core/Blob";
import List "mo:core/List";

import ICRC84 "mo:icrc-84";

import TokenHandler "../src";
import TokenHandlerContext "../src/TokenHandlerContext";
import Types "../src/types";

persistent actor class Example() = self {
  // ensure compliance to ICRC84 standart.
  // actor won't compile in case of type mismatch here
  transient let _ : ICRC84.ICRC84 = self;

  type AssetInfo = {
    ledgerPrincipal : Principal;
    handler : TokenHandler.TokenHandler;
  };
  type Journal = List.List<(Time.Time, Principal, TokenHandler.LogEvent)>;

  let assets : List.List<AssetInfo> = List.empty();
  let journal : Journal = List.empty();

  transient let handlerCtxs : List.List<Types.TokenHandlerContext> = assets.map<AssetInfo, Types.TokenHandlerContext>(
    func(assetInfo) = TokenHandlerContext.new(
      assetInfo.handler,
      {
        ledgerApi = TokenHandler.buildLedgerApi(assetInfo.ledgerPrincipal);
        log = func(p : Principal, event : TokenHandler.LogEvent) {
          journal.add((Time.now(), p, event));
        };
      },
    )
  );

  private func createTokenHandler() : TokenHandler.TokenHandler {
    TokenHandler.new({
      ownPrincipal = Principal.fromActor(self);
      initialFee = 0;
      triggerOnNotifications = true;
    });
  };

  public shared query func icrc84_supported_tokens() : async [Principal] {
    Array.tabulate<Principal>(
      List.size(assets),
      func(i) = List.at(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async ICRC84.TokenInfo {
    for ((i, assetInfo) in List.enumerate(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return {
          deposit_fee = assetInfo.handler.fee(#deposit);
          withdrawal_fee = assetInfo.handler.fee(#withdrawal);
          allowance_fee = assetInfo.handler.fee(#allowance);
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrc84_query(tokens : [Principal]) : async ([(
    Principal,
    {
      credit : Int;
      tracked_deposit : ?Nat;
    },
  )]) {
    let ret : List.List<(Principal, { credit : Int; tracked_deposit : ?Nat })> = List.empty();
    for (token in tokens.vals()) {
      let ?assetInfo = getAssetInfo(token) else throw Error.reject("Unknown token");
      let credit = assetInfo.handler.userCredit(caller);
      if (credit > 0) {
        let tracked_deposit = assetInfo.handler.trackedDeposit(caller);
        List.add(ret, (token, { credit; tracked_deposit }));
      };
    };
    List.toArray(ret);
  };

  public shared ({ caller }) func icrc84_notify(args : ICRC84.NotifyArgs) : async ICRC84.NotifyResponse {
    let ?assetIndex = getAssetIndex(args.token) else throw Error.reject("Unknown token");
    let assetInfo = assets.at(assetIndex);
    let result = try {
      await* TokenHandler.notify(assetInfo.handler, caller, handlerCtxs.at(assetIndex));
    } catch (err) {
      return #Err(#CallLedgerError({ message = Error.message(err) }));
    };
    switch (result) {
      case (?(deposit_inc, credit_inc)) {
        #Ok({
          deposit_inc;
          credit_inc;
          credit = assetInfo.handler.userCredit(caller);
        });
      };
      case null {
        #Err(#NotAvailable({ message = "" }));
      };
    };
  };

  public shared ({ caller }) func icrc84_deposit(args : ICRC84.DepositArgs) : async ICRC84.DepositResponse {
    let ?assetIndex = getAssetIndex(args.token) else throw Error.reject("Unknown token");
    let assetInfo = assets.at(assetIndex);
    let res = await* TokenHandler.depositFromAllowance(assetInfo.handler, caller, args.from, args.amount, args.expected_fee, handlerCtxs.at(assetIndex));
    switch (res) {
      case (#ok(credit_inc, txid)) #Ok({
        txid;
        credit_inc;
        credit = assetInfo.handler.userCredit(caller);
      });
      case (#err err) {
        switch (err) {
          case (#BadFee({ expected_fee })) #Err(#BadFee({ expected_fee }));
          case (#InsufficientFunds(_)) #Err(#TransferError({ message = "Insufficient funds" }));
          case (#InsufficientAllowance(_)) #Err(#TransferError({ message = "Insufficient allowance" }));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case _ #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  public shared ({ caller }) func icrc84_withdraw(args : ICRC84.WithdrawArgs) : async ICRC84.WithdrawResponse {
    let ?assetIndex = getAssetIndex(args.token) else throw Error.reject("Unknown token");
    let assetInfo = assets.at(assetIndex);

    switch (args.to.subaccount) {
      case (?subaccount) {
        let bytes = Blob.toArray(subaccount);
        if (bytes.size() != 32) throw Error.reject("Invalid subaccount");
      };
      case null {};
    };

    let res = await* TokenHandler.withdrawFromCredit(assetInfo.handler, caller, args.to, args.amount, args.expected_fee, handlerCtxs.at(assetIndex));
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        switch (err) {
          case (#InsufficientCredit) #Err(#InsufficientCredit({}));
          case (#BadFee({ expected_fee })) #Err(#BadFee({ expected_fee }));
          case (#TooLowQuantity) #Err(#AmountBelowMinimum({}));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case _ #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  // A timer for consolidating backlog subaccounts
  ignore Timer.recurringTimer<system>(
    #seconds 60,
    func() : async () {
      for (i in assets.keys()) {
        await* TokenHandler.trigger(assets.at(i).handler, 10, handlerCtxs.at(i));
      };
    },
  );

  private func getAssetIndex(icrc1Ledger : Principal) : ?Nat {
    for ((i, assetInfo) in assets.enumerate()) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?i;
      };
    };
    return null;
  };

  private func getAssetInfo(icrc1Ledger : Principal) : ?AssetInfo {
    getAssetIndex(icrc1Ledger).map(func n = assets.at(n));
  };

  public shared func registerAsset(ledger : Principal) : async {
    #Ok : Nat;
    #Err : { #AlreadyRegistered : Nat };
  } {
    // validate ledger
    let canister = actor (Principal.toText(ledger)) : (actor { icrc1_metadata : () -> async [Any] });
    try {
      ignore await canister.icrc1_metadata();
    } catch (err) {
      throw err;
    };
    for ((i, assetInfo) in List.enumerate(assets)) {
      if (Principal.equal(ledger, assetInfo.ledgerPrincipal)) return #Err(#AlreadyRegistered(i));
    };
    let id = assets.size();
    let handler = createTokenHandler();
    assets.add({
      ledgerPrincipal = ledger;
      handler;
    });
    handlerCtxs.add(
      TokenHandlerContext.new(
        handler,
        {
          ledgerApi = TokenHandler.buildLedgerApi(ledger);
          log = func(p : Principal, event : TokenHandler.LogEvent) {
            journal.add((Time.now(), p, event));
          };
        },
      )
    );
    #Ok(id);
  };

};
