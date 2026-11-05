// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ERC20
/// @notice ERC-20 written from scratch. Every change of a balance or of the
///         total supply happens in exactly one function, `_update`.
/// @dev Mint is `_update(0, to, v)`, burn is `_update(from, 0, v)` and a transfer
///      is `_update(from, to, v)`. A token that adds a cap, a pause or a fee
///      overrides `_update` and nothing else, so a new code path cannot forget a
///      rule. The metadata is set through `_setMetadata` instead of a constructor
///      so that the same base also works behind a proxy (bonus E4).
abstract contract ERC20 {
    // slot 0, 1, 2, 3, 4 -- the order is deliberate: the balances mapping sits in
    // slot 0, so a balance is at keccak256(abi.encode(account, uint256(0))).
    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidReceiver(address receiver);
    error InvalidSpender(address spender);

    function _setMetadata(string memory name_, string memory symbol_) internal {
        _name = name_;
        _symbol = symbol_;
    }

    // ------------------------------------------------------------------ views

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    // --------------------------------------------------------------- external

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @dev `approve` overwrites the allowance. It cannot say "only if the old
    ///      value is still X", which is the root of the approve race
    ///      (`test_ApproveRaceCondition`). `permit` with its nonce is the
    ///      single-use alternative.
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // --------------------------------------------------------------- internal

    /// @dev `from` is always msg.sender or an owner whose allowance was just
    ///      spent, so it can never be the zero address here.
    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert InvalidReceiver(address(0));
        _update(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert InvalidReceiver(address(0));
        _update(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        _update(from, address(0), value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (spender == address(0)) revert InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @dev An allowance of type(uint256).max means "unlimited" and is never
    ///      reduced, which also saves one SSTORE per spend.
    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert InsufficientAllowance(spender, current, value);
        unchecked {
            _allowances[owner][spender] = current - value;
        }
    }

    // ------------------------------------------------------------- the funnel

    /// @dev The only function that writes `_balances` or `_totalSupply`.
    ///      An override must call `super._update` to move the tokens.
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Checked: the total supply bounds every balance, so once this
            // addition cannot overflow, none of the unchecked ones below can.
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
            unchecked {
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // value <= fromBalance <= _totalSupply
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // a balance never exceeds _totalSupply, which did not overflow
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }
}
