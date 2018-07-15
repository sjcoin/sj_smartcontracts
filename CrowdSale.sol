pragma solidity ^0.4.23;

/*
표준 코드 라이브러리인 Open-Zepplin 코드기반으로 일부 기능이 추가 되었습니다.
*/

// ERC20 표준 인터페이스 
// SRC: zeppelin-solidity/contracts/token/ERC20/ERC20.sol
contract ERC20 {
    function allowance(address owner, address spender) public view returns (uint256);
    function transferFrom(address from, address to, uint256 value) public returns (bool);
    function approve(address spender, uint256 value) public returns (bool);
    function totalSupply() public view returns (uint256);
    function balanceOf(address who) public view returns (uint256);
    function transfer(address to, uint256 value) public returns (bool);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
}

// 오버플로우 공격등에 취약점에 대해 저항성을 가지는 계산용 라이브러리 입니다. 
// SRC: zeppelin-solidity/contracts/math/SafeMath.sol
library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0) { return 0; }
        c = a * b;
        assert(c / a == b);
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b <= a);
        return a - b;
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        assert(c >= a);
        return c;
    }
}

// 스마트 계약 선언
// SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
contract Crowdsale {
    using SafeMath for uint256;

    ERC20 public token;   // 토큰이 발행된 스마트 계약 참조 주소
    address public owner; // 스마트 계약의 소유자 (꽌리자 권한)
    
    address public tokenWallet; // 세일중인 토큰을 보유하고 있는 계좌
    address public ethWallet;   // 토큰을 판매하고 받은 이더가 저장되는 계좌
    address public devWallet;   // 개발팀 지분을 수령할 계좌
    
    uint256 public rate = 50000; // 교환 비율 1ETH = 200,000 XSJ 
    uint256 public weiRaised;   // 토큰을 판매하고 받은 이더리움의 양 (Wei 단위)
    
    uint256 public openingTime = 1531396800; // 퍼블릭 세일 개시일 (2018-07-12 PM 09)
    uint256 public closingTime = 1532347200; // 퍼블릭 세일 종료일 (2018-07-23 PM 09)

    uint256 public MAX_CAP = 1500 ether;     // 하드캡: 1500 이더리움
    uint256 public MAX_BUY_ETH = 8 ether;    // 최대 구매액: 8 이더리움
    uint256 public MIN_BUY_ETH = 0.4 ether;  // 최소 구매액: 0.4 이더리움
    
    // 720 days = 63,072,000 second (1day = 86400)
    // 240 ether = 240 * 1000 000 0000(Gwei) / 720 Days = 3805 Gwei per Second

    // 개발팀은 240이더 어치의 토큰을 2년간에 걸쳐서 (매달 5.5% 씩) 수령할 권한을 가지게 됩니다.
    uint256 public TOTAL_DEV_SHARES = 240 ether; // 개발팀이 2년간 수령할 토큰의 총 이더리움 가치
    uint256 public MAX_DEV_TOKENS;  // TOTAL_DEV_SHARES를 토큰으로 환산한 수량
    uint256 public DEV_TOKEN_WEI_PER_SEC = 3805100000000; // 매초마다 발생되는 개발팀 지분의 WEI 환산가치
    uint256 public transferredDevToken = 0;
    
    // 아래와 같은 행위 발생시, 이벤트가 발생되어 네트워크에 공지가 됩니다. 
    event OwnershipRenounced(address indexed previousOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

    // 스마트 계약 생성자(초기화)
    constructor(address _tokenWallet, address _ethWallet, address _devWallet, ERC20 _token) public {
        require(_tokenWallet != address(0));
        require(_ethWallet != address(0));
        require(_token != address(0));

        owner        = msg.sender;
        token        = _token;
        ethWallet    = _ethWallet;
        tokenWallet  = _tokenWallet;
        devWallet    = _devWallet;
        MAX_DEV_TOKENS = _getTokenAmount(TOTAL_DEV_SHARES);
    }

    // Ownable, 관리자만 함수를 실행할 수 있게 제한합니다.
    // SRC: zeppelin-solidity/contracts/ownership/Ownable.sol
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // CrowdSale이 오픈기간 중에만 실행할 수 있게 제한합니다. 
    // SRC: zeppelin-solidity/contracts/crowdsale/validation/TimedCrowdsale.sol
    modifier onlyWhileOpen {
        require(block.timestamp >= openingTime && block.timestamp <= closingTime);
        _;
    }
  
    // 관리자 계정을 다른 주소로 이전합니다.
    // SRC: zeppelin-solidity/contracts/ownership/Ownable.sol
    function transferOwnership(address _newOwner) public onlyOwner { _transferOwnership(_newOwner); }
    function _transferOwnership(address _newOwner) internal {
        require(_newOwner != address(0));
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // 개발팀의 토큰 수령 주소를 변경 합니다. (지갑 변경시)
    function changeDevWallet(address _devWallet) public onlyOwner { _changeDevWallet(_devWallet); }
    function _changeDevWallet(address _devWallet) internal {
        require(_devWallet != address(0));
        devWallet = _devWallet;
    }
    
    // 이더리움이 적립될 지갑 주소를 변경 합니다.
    function changeEthWallet(address _ethWallet) public onlyOwner { _changeEthWallet(_ethWallet); }
    function _changeEthWallet(address _ethWallet) internal {
        require(_ethWallet != address(0));
        ethWallet = _ethWallet;
    }
    
    // 하드캡이 다 찼는지 여부를 반환합니다.
    function capReached() public view returns (bool) {
        return (weiRaised >= MAX_CAP);
    }

    // 세일이 끝났는지 여부를 반환합니다. 
    // SRC: zeppelin-solidity/contracts/crowdsale/validation/TimedCrowdsale.sol
    function hasClosed() public view returns (bool) {
        return (block.timestamp > closingTime);
    }
    
    // 세일 종료 시간을 변경합니다. 
    function setClosingTime(uint256 _closingTime) public onlyOwner {
        require(_closingTime >= openingTime);
        closingTime = _closingTime;
    }
    
    // -----------------------------------------
    // Crowdsale external interface
    // -----------------------------------------

    // 해당 계약으로 이더리움을 전송하면, 토큰을 보냅니다. 
    //[NOTE] fallback function ***DO NOT OVERRIDE***
    function () external payable {
        buyTokens(msg.sender);
    }

    // 실제 이더리움을 토큰으로 환산하여 지불하는 함수입니다. 
    /* low level token purchase ***DO NOT OVERRIDE*** */
    // SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
    function buyTokens(address _beneficiary) public payable {
        require(MAX_BUY_ETH >= msg.value);
        require(MIN_BUY_ETH <= msg.value); 
        
        uint256 weiAmount = msg.value;
        uint256 tokens = _getTokenAmount(weiAmount);

        _preValidatePurchase(_beneficiary, weiAmount);

        // update state
        weiRaised = weiRaised.add(weiAmount);
        
        _processPurchase(_beneficiary, tokens);
        emit TokenPurchase(msg.sender, _beneficiary, weiAmount, tokens);
        
        _forwardFunds();
    }

    // 사전 채크 함수, 세일 기간이 끝났는지, 캡은 다 채웟는지를 확인합니다.
    // SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount) internal view onlyWhileOpen {
        require(block.timestamp < closingTime);
        require(weiRaised.add(_weiAmount) <= MAX_CAP);
    }

    // 토큰을 전달하는 함수입니다.
    // SRC: zeppelin-solidity/contracts/crowdsale/emission/AllowanceCrowdsale.sol
    function _deliverTokens(address _beneficiary, uint256 _tokenAmount) internal {
        token.transferFrom(tokenWallet, _beneficiary, _tokenAmount);
    }

    // 구매 행위를 수행하는 함수입니다. (토큰을 전송합니다.)
    // SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
    function _processPurchase(address _beneficiary, uint256 _tokenAmount) internal {
        _deliverTokens(_beneficiary, _tokenAmount);
    }

    // 이더리움(wei단위)당 토큰을 반환합니다. (토큰수는 소숫점 8자리이므로, 뒤에 0, 8개를 뺍니다.)
    // SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
    function _getTokenAmount(uint256 _weiAmount) internal view returns (uint256) {
        return _weiAmount.div(rate);
        //[NOTE] Original Code -> return _weiAmount.mul(rate);
    }

    // 이더리움(wei단위)당 토큰을 반환합니다. (토큰수는 소숫점 8자리이므로, 뒤에 0, 8개를 뺍니다.)
    // SRC: zeppelin-solidity/contracts/crowdsale/Crowdsale.sol
    function getTokenAmount(uint256 _weiAmount) public view returns (uint256) {
        return _weiAmount.div(rate);
        //[NOTE] Original Code -> return _weiAmount.mul(rate);
    }
    
    // 받은 이더리움을 이더리움 보관 월렛주소로 전송합니다. 
    // SRC: zeppelin-solidity/contracts/crowdsale/emission/AllowanceCrowdsale.sol
    function _forwardFunds() internal {
        ethWallet.transfer(msg.value);
    }
    
    // 현재 남아있는 토큰수를 반환합니다. 
    // SRC: zeppelin-solidity/contracts/crowdsale/emission/AllowanceCrowdsale.sol
    function remainingTokens() public view returns (uint256) {
        return token.allowance(tokenWallet, this);
    }
    
    // 현재 적립되어 있는 토큰수를 반환합니다. 
    function remainingDevTokens() public view returns (uint256) {
        uint256 devAcc = (block.timestamp - openingTime) * DEV_TOKEN_WEI_PER_SEC;
        uint256 tokens = _getTokenAmount(devAcc);
        
        if (MAX_DEV_TOKENS < tokens) 
            tokens = MAX_DEV_TOKENS;
            
        return (tokens - transferredDevToken);
    }

    // 락업이 풀린 토큰을 개발팀 지갑으로 전송 받습니다. 
    // Lockup for Development team ---------------------------------------------------
    function withdrawDevTokens() public onlyOwner {
        require(MAX_DEV_TOKENS > transferredDevToken);
        
        uint256 tokens = remainingDevTokens();
        transferredDevToken = transferredDevToken.add(tokens);
        
        token.transfer(devWallet, tokens);
    }

}
