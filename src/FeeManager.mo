module {
  public class FeeManager(initialFee : Nat) {
    var ledgerFee_ = initialFee;
    var surcharge_ = 0;

    public func fee() : Nat = ledgerFee_ + surcharge_;

    public func ledgerFee() : Nat = ledgerFee_;

    public func surcharge() : Nat = surcharge_;

    public func setSurcharge(s : Nat) {
      surcharge_ := s;
    };

    public func setLedgerFee(f : Nat) {
      ledgerFee_ := f;
    };
  };
};