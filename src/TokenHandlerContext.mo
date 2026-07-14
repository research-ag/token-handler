import ICRC1 "icrc1-api";
import Types "types";
import TokenHandler "lib";

// A transient type for TokenHandler callbacks, shared functions, API
module {

  public type TokenHandlerContextOptions = {
    ledgerApi : ICRC1.API;
    log : (Principal, Types.LogEvent) -> ();
  };

  public func new(handler : TokenHandler.TokenHandler, options : TokenHandlerContextOptions) : Types.TokenHandlerContext {
    let ctx = {
      ownPrincipal = handler.ownPrincipal;
      api = options.ledgerApi;
      assertInvariant = func() : Bool = TokenHandler.assertInvariant(handler, ctx);
      onFeeChanged = func(oldFee : Nat, newFee : Nat) = TokenHandler.onFeeChanged(handler, oldFee : Nat, newFee : Nat, ctx);
      log = options.log;
      var isFrozen_ = false;
    };
    return ctx;
  };

};
