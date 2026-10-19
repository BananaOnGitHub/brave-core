/* Copyright (c) 2024 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "brave/components/brave_wallet/browser/meld_integration_service.h"

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/test/bind.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/test/values_test_util.h"
#include "base/values.h"
#include "brave/components/brave_wallet/browser/brave_wallet_constants.h"
#include "brave/components/brave_wallet/common/meld_integration.mojom.h"
#include "components/grit/brave_components_strings.h"
#include "net/base/url_search_params.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "services/network/test/test_url_loader_factory.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "ui/base/l10n/l10n_util.h"

namespace {

using testing::ElementsAre;
using testing::Pair;

void CheckOptString(const std::string* val,
                    const std::optional<std::string>& val_to_check) {
  if (val_to_check) {
    EXPECT_TRUE(val);
    EXPECT_EQ(val_to_check, *val);
  } else {
    EXPECT_FALSE(val);
  }
}
void CheckString(const std::string* val, const std::string& val_to_check) {
  EXPECT_TRUE(val);
  EXPECT_EQ(val_to_check, *val);
}
}  // namespace

namespace brave_wallet {

class MeldIntegrationServiceUnitTest : public testing::Test {
 public:
  MeldIntegrationServiceUnitTest() {
    meld_integration_service_ = std::make_unique<MeldIntegrationService>(
        url_loader_factory_.GetSafeWeakWrapper());
  }

  ~MeldIntegrationServiceUnitTest() override = default;

  using OnRequestPayloadCallback =
      base::RepeatingCallback<void(const std::string& request_payload)>;

  // Every service method reports errors through this trailing parameter. Note
  // it is passed by const ref, so the explicit `GetCallback<Result, const
  // Errors&>()` form is required to match the generated callback type.
  using Errors = std::optional<std::vector<std::string>>;

  void SetInterceptor(
      const std::string& content,
      const net::HttpStatusCode http_status,
      OnRequestPayloadCallback* request_payload_callback = nullptr) {
    url_loader_factory_.SetInterceptor(base::BindLambdaForTesting(
        [&, content, http_status,
         request_payload_callback](const network::ResourceRequest& request) {
          url_loader_factory_.ClearResponses();
          auto header =
              request.headers.GetHeader(brave_wallet::kMeldRpcVersionHeader);
          EXPECT_TRUE(header);
          EXPECT_FALSE(header->empty());

          if (request_payload_callback) {
            std::string request_string(request.request_body->elements()
                                           ->at(0)
                                           .As<network::DataElementBytes>()
                                           .AsStringPiece());
            request_payload_callback->Run(request_string);
          }
          url_loader_factory_.AddResponse(request.url.spec(), content,
                                          http_status);
        }));
  }

  auto TestGetServiceProvider(
      const std::string& content,
      const net::HttpStatusCode http_status = net::HTTP_OK) {
    SetInterceptor(content, http_status);

    using Result = std::optional<std::vector<mojom::MeldServiceProviderPtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetServiceProviders(
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestGetCryptoQuotes(
      const std::string& content,
      const std::string& country,
      const std::string& from_asset,
      const std::string& to_asset,
      const double source_amount,
      const std::optional<std::string>& account,
      const std::optional<std::string>& payment_method,
      const net::HttpStatusCode http_status = net::HTTP_OK) {
    auto request_payload_check_callback = base::BindRepeating(
        [](const std::string& country, const std::string& from_asset,
           const std::string& to_asset, const double source_amount,
           const std::optional<std::string>& account,
           const std::optional<std::string>& payment_method,
           const std::string& request_payload) {
          auto request_payload_value = base::test::ParseJson(request_payload);
          EXPECT_TRUE(request_payload_value.is_dict());
          auto& request_payload_dict = request_payload_value.GetDict();

          CheckString(request_payload_dict.FindString("countryCode"), country);
          CheckString(request_payload_dict.FindString("sourceCurrencyCode"),
                      from_asset);
          CheckString(
              request_payload_dict.FindString("destinationCurrencyCode"),
              to_asset);
          EXPECT_EQ(request_payload_dict.FindDouble("sourceAmount"),
                    source_amount);

          CheckOptString(request_payload_dict.FindString("walletAddress"),
                         account);
          CheckOptString(request_payload_dict.FindString("paymentMethodType"),
                         payment_method);
        },
        country, from_asset, to_asset, source_amount, account, payment_method);

    SetInterceptor(content, http_status, &request_payload_check_callback);

    using Result = std::optional<std::vector<mojom::MeldCryptoQuotePtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetCryptoQuotes(
        country, from_asset, to_asset, source_amount, account, payment_method,
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestGetPaymentMethods(
      const std::string& content,
      const std::string& country,
      const std::string& source_currency_code,
      const net::HttpStatusCode http_status = net::HTTP_OK) {
    SetInterceptor(content, http_status);

    using Result = std::optional<std::vector<mojom::MeldPaymentMethodPtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetPaymentMethods(
        country, source_currency_code,
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestGetFiatCurrencies(
      const std::string& content,
      const net::HttpStatusCode http_status = net::HTTP_OK) {
    SetInterceptor(content, http_status);

    using Result = std::optional<std::vector<mojom::MeldFiatCurrencyPtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetFiatCurrencies(
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestGetCryptoCurrencies(
      const std::string& content,
      const net::HttpStatusCode http_status = net::HTTP_OK) {
    SetInterceptor(content, http_status);

    using Result = std::optional<std::vector<mojom::MeldCryptoCurrencyPtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetCryptoCurrencies(
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestGetCountries(const std::string& content,
                        const net::HttpStatusCode http_status = net::HTTP_OK) {
    SetInterceptor(content, http_status);

    using Result = std::optional<std::vector<mojom::MeldCountryPtr>>;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->GetCountries(
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestCryptoBuyWidgetCreate(
      const std::string& content,
      const std::string& country_code,
      const std::string& destination_currency_code,
      std::optional<std::vector<std::string>> lock_fields,
      const std::optional<std::string>& payment_method_type,
      const std::optional<std::string>& redirect_url,
      const std::string& service_provider,
      const std::string& source_amount,
      const std::string& source_currency_code,
      const std::string& wallet_address,
      const std::optional<std::string>& wallet_tag,
      const std::optional<std::string>& customer_object_email,
      const std::optional<std::string>& customer_id,
      const std::optional<std::string>& external_customer_id,
      const std::optional<std::string>& external_session_id,
      const net::HttpStatusCode http_status = net::HTTP_OK,
      const bool is_session_data_null = false) {
    mojom::CryptoBuySessionDataPtr session_data;
    if (!is_session_data_null) {
      session_data = mojom::CryptoBuySessionData::New(
          country_code, destination_currency_code, lock_fields,
          payment_method_type, redirect_url, service_provider, source_amount,
          source_currency_code, wallet_address, wallet_tag);
    }

    mojom::CryptoWidgetCustomerDataPtr customer_data;
    if (customer_object_email || customer_id || external_customer_id ||
        external_session_id) {
      customer_data = mojom::CryptoWidgetCustomerData::New(
          customer_object_email
              ? mojom::CustomerObject::New(customer_object_email.value())
              : nullptr,
          customer_id, external_customer_id, external_session_id);
    }

    auto request_payload_check_callback = base::BindRepeating(
        [](const std::optional<std::string>& customer_id,
           const std::optional<std::string>& external_customer_id,
           const std::optional<std::string>& external_session_id,
           const std::string& country_code,
           const std::string& destination_currency_code,
           const std::optional<std::string>& payment_method_type,
           const std::optional<std::string>& redirect_url,
           const std::string& service_provider,
           const std::string& source_amount,
           const std::string& source_currency_code,
           const std::string& wallet_address,
           const std::optional<std::string>& wallet_tag,
           const std::string& request_payload) {
          auto request_payload_value = base::test::ParseJson(request_payload);
          EXPECT_TRUE(request_payload_value.is_dict());
          auto& request_payload_dict = request_payload_value.GetDict();

          CheckString(request_payload_dict.FindString("sessionType"), "BUY");

          CheckOptString(request_payload_dict.FindString("customerId"),
                         customer_id);
          CheckOptString(request_payload_dict.FindString("externalCustomerId"),
                         external_customer_id);
          CheckOptString(request_payload_dict.FindString("externalSessionId"),
                         external_session_id);

          auto* session_data_dict =
              request_payload_dict.FindDict("sessionData");
          EXPECT_TRUE(session_data_dict);
          CheckString(session_data_dict->FindString("countryCode"),
                      country_code);
          CheckString(session_data_dict->FindString("destinationCurrencyCode"),
                      destination_currency_code);
          CheckOptString(session_data_dict->FindString("paymentMethodType"),
                         payment_method_type);
          CheckOptString(session_data_dict->FindString("redirectUrl"),
                         redirect_url);
          CheckString(session_data_dict->FindString("serviceProvider"),
                      service_provider);
          CheckString(session_data_dict->FindString("sourceAmount"),
                      source_amount);
          CheckString(session_data_dict->FindString("sourceCurrencyCode"),
                      source_currency_code);
          CheckString(session_data_dict->FindString("walletAddress"),
                      wallet_address);
          CheckOptString(session_data_dict->FindString("walletTag"),
                         wallet_tag);
        },
        customer_id, external_customer_id, external_session_id, country_code,
        destination_currency_code, payment_method_type, redirect_url,
        service_provider, source_amount, source_currency_code, wallet_address,
        wallet_tag);

    SetInterceptor(content, http_status, &request_payload_check_callback);

    using Result = mojom::MeldCryptoWidgetPtr;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->CryptoBuyWidgetCreate(
        std::move(session_data), std::move(customer_data),
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestCryptoSellWidgetCreate(
      const std::string& content,
      const std::string& country_code,
      const std::string& destination_currency_code,
      std::optional<std::vector<std::string>> lock_fields,
      const std::optional<std::string>& payment_method_type,
      const std::optional<std::string>& redirect_url,
      const std::string& service_provider,
      const std::string& source_amount,
      const std::string& source_currency_code,
      const std::optional<std::string>& wallet_address,
      const std::optional<std::string>& wallet_tag,
      const std::optional<std::string>& customer_object_email,
      const std::optional<std::string>& customer_id,
      const std::optional<std::string>& external_customer_id,
      const std::optional<std::string>& external_session_id,
      const net::HttpStatusCode http_status = net::HTTP_OK,
      const bool is_session_data_null = false) {
    mojom::CryptoSellSessionDataPtr session_data;
    if (!is_session_data_null) {
      session_data = mojom::CryptoSellSessionData::New(
          country_code, destination_currency_code, lock_fields,
          payment_method_type, redirect_url, service_provider, source_amount,
          source_currency_code, wallet_address, wallet_tag);
    }

    mojom::CryptoWidgetCustomerDataPtr customer_data;
    if (customer_object_email || customer_id || external_customer_id ||
        external_session_id) {
      customer_data = mojom::CryptoWidgetCustomerData::New(
          customer_object_email
              ? mojom::CustomerObject::New(customer_object_email.value())
              : nullptr,
          customer_id, external_customer_id, external_session_id);
    }

    auto request_payload_check_callback = base::BindRepeating(
        [](const std::optional<std::string>& customer_id,
           const std::optional<std::string>& external_customer_id,
           const std::optional<std::string>& external_session_id,
           const std::string& country_code,
           const std::string& destination_currency_code,
           const std::optional<std::string>& payment_method_type,
           const std::optional<std::string>& redirect_url,
           const std::string& service_provider,
           const std::string& source_amount,
           const std::string& source_currency_code,
           const std::optional<std::string>& wallet_address,
           const std::optional<std::string>& wallet_tag,
           const std::string& request_payload) {
          auto request_payload_value = base::test::ParseJson(request_payload);
          EXPECT_TRUE(request_payload_value.is_dict());
          auto& request_payload_dict = request_payload_value.GetDict();

          CheckString(request_payload_dict.FindString("sessionType"), "SELL");

          CheckOptString(request_payload_dict.FindString("customerId"),
                         customer_id);
          CheckOptString(request_payload_dict.FindString("externalCustomerId"),
                         external_customer_id);
          CheckOptString(request_payload_dict.FindString("externalSessionId"),
                         external_session_id);

          auto* session_data_dict =
              request_payload_dict.FindDict("sessionData");
          EXPECT_TRUE(session_data_dict);
          CheckString(session_data_dict->FindString("countryCode"),
                      country_code);
          CheckString(session_data_dict->FindString("destinationCurrencyCode"),
                      destination_currency_code);
          CheckOptString(session_data_dict->FindString("paymentMethodType"),
                         payment_method_type);
          CheckOptString(session_data_dict->FindString("redirectUrl"),
                         redirect_url);
          CheckString(session_data_dict->FindString("serviceProvider"),
                      service_provider);
          CheckString(session_data_dict->FindString("sourceAmount"),
                      source_amount);
          CheckString(session_data_dict->FindString("sourceCurrencyCode"),
                      source_currency_code);
          CheckOptString(session_data_dict->FindString("walletAddress"),
                         wallet_address);
          CheckOptString(session_data_dict->FindString("walletTag"),
                         wallet_tag);
        },
        customer_id, external_customer_id, external_session_id, country_code,
        destination_currency_code, payment_method_type, redirect_url,
        service_provider, source_amount, source_currency_code, wallet_address,
        wallet_tag);

    SetInterceptor(content, http_status, &request_payload_check_callback);

    using Result = mojom::MeldCryptoWidgetPtr;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->CryptoSellWidgetCreate(
        std::move(session_data), std::move(customer_data),
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

  auto TestCryptoTransferWidgetCreate(
      const std::string& content,
      const std::optional<std::string>& country_code,
      const std::optional<std::string>& institution_id,
      std::optional<std::vector<std::string>> lock_fields,
      const std::optional<std::string>& redirect_url,
      const std::string& service_provider,
      const std::optional<std::string>& source_amount,
      const std::vector<std::string>& source_currency_codes,
      const std::optional<std::string>& wallet_address,
      const std::optional<std::string>& wallet_tag,
      const std::optional<std::string>& customer_object_email,
      const std::optional<std::string>& customer_id,
      const std::optional<std::string>& external_customer_id,
      const std::optional<std::string>& external_session_id,
      const net::HttpStatusCode http_status = net::HTTP_OK,
      const bool is_session_data_null = false) {
    mojom::CryptoTransferSessionDataPtr session_data;
    if (!is_session_data_null) {
      session_data = mojom::CryptoTransferSessionData::New(
          country_code, institution_id, lock_fields, redirect_url,
          service_provider, source_amount, source_currency_codes,
          wallet_address, wallet_tag);
    }

    mojom::CryptoWidgetCustomerDataPtr customer_data;
    if (customer_object_email || customer_id || external_customer_id ||
        external_session_id) {
      customer_data = mojom::CryptoWidgetCustomerData::New(
          customer_object_email
              ? mojom::CustomerObject::New(customer_object_email.value())
              : nullptr,
          customer_id, external_customer_id, external_session_id);
    }

    auto request_payload_check_callback = base::BindRepeating(
        [](const std::optional<std::string>& customer_id,
           const std::optional<std::string>& external_customer_id,
           const std::optional<std::string>& external_session_id,
           const std::optional<std::string>& country_code,
           const std::optional<std::string>& institution_id,
           const std::optional<std::string>& redirect_url,
           const std::string& service_provider,
           const std::optional<std::string>& source_amount,
           const std::vector<std::string>& source_currency_codes,
           const std::optional<std::string>& wallet_address,
           const std::optional<std::string>& wallet_tag,
           const std::string& request_payload) {
          auto request_payload_value = base::test::ParseJson(request_payload);
          EXPECT_TRUE(request_payload_value.is_dict());
          auto& request_payload_dict = request_payload_value.GetDict();

          CheckString(request_payload_dict.FindString("sessionType"),
                      "TRANSFER");

          CheckOptString(request_payload_dict.FindString("customerId"),
                         customer_id);
          CheckOptString(request_payload_dict.FindString("externalCustomerId"),
                         external_customer_id);
          CheckOptString(request_payload_dict.FindString("externalSessionId"),
                         external_session_id);

          auto* session_data_dict =
              request_payload_dict.FindDict("sessionData");
          EXPECT_TRUE(session_data_dict);
          CheckOptString(session_data_dict->FindString("countryCode"),
                         country_code);
          CheckOptString(session_data_dict->FindString("institutionId"),
                         institution_id);
          CheckOptString(session_data_dict->FindString("redirectUrl"),
                         redirect_url);
          CheckString(session_data_dict->FindString("serviceProvider"),
                      service_provider);
          CheckOptString(session_data_dict->FindString("sourceAmount"),
                         source_amount);

          auto* source_currency_codes_list =
              session_data_dict->FindList("sourceCurrencyCodes");
          ASSERT_TRUE(source_currency_codes_list);
          base::ListValue expected_codes;
          for (const auto& code : source_currency_codes) {
            expected_codes.Append(code);
          }
          EXPECT_EQ(*source_currency_codes_list, expected_codes);
          CheckOptString(session_data_dict->FindString("walletAddress"),
                         wallet_address);
          CheckOptString(session_data_dict->FindString("walletTag"),
                         wallet_tag);
        },
        customer_id, external_customer_id, external_session_id, country_code,
        institution_id, redirect_url, service_provider, source_amount,
        source_currency_codes, wallet_address, wallet_tag);

    SetInterceptor(content, http_status, &request_payload_check_callback);

    using Result = mojom::MeldCryptoWidgetPtr;
    base::test::TestFuture<Result, Errors> future;
    meld_integration_service_->CryptoTransferWidgetCreate(
        std::move(session_data), std::move(customer_data),
        future.GetCallback<Result, const Errors&>());
    return future.Take();
  }

 protected:
  std::unique_ptr<MeldIntegrationService> meld_integration_service_;
  base::test::TaskEnvironment task_environment_;

 private:
  network::TestURLLoaderFactory url_loader_factory_;
};

TEST_F(MeldIntegrationServiceUnitTest, GetServiceProviders) {
  std::optional<std::vector<mojom::MeldServiceProviderPtr>> sps;
  Errors errors;

  const auto url = MeldIntegrationService::GetServiceProviderURL();
  EXPECT_EQ(url.path(), "/service-providers");
  EXPECT_THAT(net::UrlSearchParams(url).params(),
              ElementsAre(Pair("accountFilter", "false"),
                          Pair("statuses", "LIVE,RECENTLY_ADDED")));
  std::tie(sps, errors) = TestGetServiceProvider(R"([
  {
    "serviceProvider": "BANXA",
    "name": "Banxa",
    "status": "LIVE",
    "categories": [
      "CRYPTO_ONRAMP"
    ],
    "categoryStatuses": {
      "CRYPTO_ONRAMP": "LIVE"
    },
    "websiteUrl": "http://www.banxa.com",
    "logos": {
      "darkShort": "https://images-serviceprovider.meld.io/BANXA/short_logo_dark.png",
      "lightShort": null
    }
  },
  {
    "serviceProvider": "BLOCKCHAINDOTCOM",
    "name": "Blockchain.com",
    "status": "LIVE",
    "categories": [
      "CRYPTO_ONRAMP"
    ],
    "categoryStatuses": {
      "CRYPTO_ONRAMP": "LIVE"
    },
    "websiteUrl": "https://www.blockchain.com",
    "logos": null
  }])");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(sps);

  std::vector<mojom::MeldServiceProviderPtr> expected;
  expected.push_back(mojom::MeldServiceProvider::New(
      "Banxa", "BANXA", "LIVE", "http://www.banxa.com",
      std::vector<std::string>{"CRYPTO_ONRAMP"},
      base::flat_map<std::string, std::string>{{"CRYPTO_ONRAMP", "LIVE"}},
      "https://images-serviceprovider.meld.io/BANXA/short_logo_dark.png",
      std::nullopt));
  expected.push_back(mojom::MeldServiceProvider::New(
      "Blockchain.com", "BLOCKCHAINDOTCOM", "LIVE",
      "https://www.blockchain.com", std::vector<std::string>{"CRYPTO_ONRAMP"},
      base::flat_map<std::string, std::string>{{"CRYPTO_ONRAMP", "LIVE"}},
      std::nullopt, std::nullopt));
  EXPECT_EQ(*sps, expected);

  std::tie(sps, errors) = TestGetServiceProvider(R"([{
    "status": "LIVE",
    "categories": [
      "CRYPTO_ONRAMP"
    ],
    "categoryStatuses": {
      "CRYPTO_ONRAMP": "LIVE"
    }
  }])");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(sps, errors) = TestGetServiceProvider(R"({
    "code": "UNAUTHORIZED",
    "message": "invalid profile or secret",
    "requestId": "315a",
    "timestamp": "2024-04-24T18:55:09.327818Z"
  })",
                                                 net::HTTP_UNAUTHORIZED);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{"invalid profile or secret"});

  std::tie(sps, errors) = TestGetServiceProvider("some wrone data");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(sps, errors) =
      TestGetServiceProvider("some wrone data", net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(sps, errors) = TestGetServiceProvider(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356d",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                                                 net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, GetCryptoQuotes) {
  std::optional<std::vector<mojom::MeldCryptoQuotePtr>> quotes;
  Errors errors;

  const std::string content = R"({
    "quotes": [
      {
        "transactionType": "CRYPTO_PURCHASE",
        "sourceAmount": 50,
        "sourceAmountWithoutFees": 43.97,
        "fiatAmountWithoutFees": 43.97,
        "destinationAmountWithoutFees": null,
        "sourceCurrencyCode": "USD",
        "countryCode": "US",
        "totalFee": 6.03,
        "networkFee": 3.53,
        "transactionFee": 2,
        "destinationAmount": 0.00066413,
        "destinationCurrencyCode": "BTC",
        "exchangeRate": 75286,
        "paymentMethodType": "APPLE_PAY",
        "customerScore": 20,
        "serviceProvider": "TRANSAK"
      }
    ],
    "message": null,
    "error": null
  })";

  auto check_parsed_content =
      [](const std::optional<std::vector<mojom::MeldCryptoQuotePtr>>& quotes,
         const std::optional<std::vector<std::string>>& errors) {
        EXPECT_FALSE(errors.has_value());
        ASSERT_TRUE(quotes);

        std::vector<mojom::MeldCryptoQuotePtr> expected;
        expected.push_back(mojom::MeldCryptoQuote::New(
            "CRYPTO_PURCHASE", "75286", "2", "USD", "50", "43.97", "43.97",
            "6.03", "3.53", "APPLE_PAY", "BTC", "0.00066413", std::nullopt,
            "20", "TRANSAK", "US"));
        EXPECT_EQ(*quotes, expected);
      };

  std::tie(quotes, errors) = TestGetCryptoQuotes(
      content, "US", "USD", "BTC", 50, "btc account address", "VISA");
  check_parsed_content(quotes, errors);

  std::tie(quotes, errors) = TestGetCryptoQuotes(
      content, "US", "USD", "BTC", 50, std::nullopt, std::nullopt);
  check_parsed_content(quotes, errors);

  std::tie(quotes, errors) = TestGetCryptoQuotes(
      "some wrong data", "US", "USD", "BTC", 50, "btc account address", "VISA",
      net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(quotes, errors) = TestGetCryptoQuotes(R"({
    "quotes": [
      {
        "transactionType": "CRYPTO_PURCHASE",
        "sourceAmount": 50,
        "sourceAmountWithoutFees": 43.97,
        "fiatAmountWithoutFees": 43.97,
        "destinationAmountWithoutFees": null,
        "sourceCurrencyCode": "USD",
        "countryCode": "US",
        "totalFee": null,
        "networkFee": 3.53,
        "transactionFee": 2,
        "destinationAmount": 0.00066413,
        "destinationCurrencyCode": "BTC",
        "exchangeRate": 75286,
        "paymentMethodType": "APPLE_PAY",
        "customerScore": 20,
        "serviceProvider": "TRANSAK"
      }
    ],
    "message": null,
    "error": "error description"
  })",
                                                 "US", "USD", "BTC", 50,
                                                 "btc account address", "VISA");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{"error description"});
  EXPECT_FALSE(quotes);

  std::tie(quotes, errors) =
      TestGetCryptoQuotes(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                          "US", "USD", "BTC", 50, "btc account address", "VISA",
                          net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));

  std::tie(quotes, errors) =
      TestGetCryptoQuotes(R"({
    "quotes": null,
    "message": null,
    "error": "No Valid Quote Combinations Found For Provided Quote Request."
  })",
                          "US", "USD", "BTC", 50, "btc account address", "VISA",
                          net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors,
            std::vector<std::string>({"No Valid Quote Combinations Found For "
                                      "Provided Quote Request."}));
}

TEST_F(MeldIntegrationServiceUnitTest, GetPaymentMethods) {
  std::optional<std::vector<mojom::MeldPaymentMethodPtr>> payment_methods;
  Errors errors;

  const auto url = MeldIntegrationService::GetPaymentMethodsURL("US", "USD");
  EXPECT_EQ(url.path(), "/network-partner/supported/payment-methods");
  EXPECT_THAT(net::UrlSearchParams(url).params(),
              ElementsAre(Pair("category", "CRYPTO_ONRAMP"),  //
                          Pair("country", "US"),              //
                          Pair("currencyCode", "USD")));
  std::tie(payment_methods, errors) = TestGetPaymentMethods(R"([
  {
    "method": "ACH",
    "name": null,
    "type": "BANK_TRANSFER",
    "logo": {
      "dark": "https://images-paymentMethod.meld.io/ACH/logo_dark.png",
      "light": "https://images-paymentMethod.meld.io/ACH/logo_light.png"
    }
  }
  ])",
                                                            "US", "USD");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(payment_methods);

  std::vector<mojom::MeldPaymentMethodPtr> expected;
  expected.push_back(mojom::MeldPaymentMethod::New(
      "ACH", std::nullopt, "BANK_TRANSFER",
      "https://images-paymentMethod.meld.io/ACH/logo_dark.png",
      "https://images-paymentMethod.meld.io/ACH/logo_light.png"));
  EXPECT_EQ(*payment_methods, expected);

  std::tie(payment_methods, errors) = TestGetPaymentMethods(R"([
  {
    "method": "ACH",
    "name": "ACH",
    "type": "BANK_TRANSFER",
    "logo": {
      "dark": null,
      "light": "https://images-paymentMethod.meld.io/ACH/logo_light.png"
    }
  }
  ])",
                                                            "US", "USD");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(payment_methods);

  std::vector<mojom::MeldPaymentMethodPtr> expected_null_dark_logo;
  expected_null_dark_logo.push_back(mojom::MeldPaymentMethod::New(
      "ACH", "ACH", "BANK_TRANSFER", std::nullopt,
      "https://images-paymentMethod.meld.io/ACH/logo_light.png"));
  EXPECT_EQ(*payment_methods, expected_null_dark_logo);

  // Payment methods are still returned as a bare list, not an object.
  std::tie(payment_methods, errors) = TestGetPaymentMethods(R"({
    "method": "ACH",
    "name": "ACH",
    "type": "BANK_TRANSFER",
    "logo": {
      "dark": null,
      "light": "https://images-paymentMethod.meld.io/ACH/logo_light.png"
    }
  })",
                                                            "US", "USD");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(payment_methods, errors) = TestGetPaymentMethods(R"([{
    "name": "ACH",
    "type": "BANK_TRANSFER",
    "logo": {
      "dark": null,
      "light": "https://images-paymentMethod.meld.io/ACH/logo_light.png"
    }
  }])",
                                                            "US", "USD");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(payment_methods, errors) = TestGetPaymentMethods(
      "some wrong data", "US", "USD", net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(payment_methods, errors) =
      TestGetPaymentMethods(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                            "US", "USD", net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, GetFiatCurrencies) {
  std::optional<std::vector<mojom::MeldFiatCurrencyPtr>> fiat_currencies;
  Errors errors;

  const auto url = MeldIntegrationService::GetFiatCurrenciesURL();
  EXPECT_EQ(url.path(), "/network-partner/supported/currencies");
  EXPECT_THAT(net::UrlSearchParams(url).params(),
              ElementsAre(Pair("category", "CRYPTO_ONRAMP"),  //
                          Pair("type", "FIAT")));

  std::tie(fiat_currencies, errors) = TestGetFiatCurrencies(R"({
  "currencies": [
    {
      "currencyCode": "AFN",
      "name": null,
      "symbol": "https://images-currency.meld.io/fiat/AFN/symbol.png"
    },
    {
      "currencyCode": "DZD",
      "name": "Algerian Dinar",
      "symbol": "https://images-currency.meld.io/fiat/DZD/symbol.png"
    }
  ]})");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(fiat_currencies);

  std::vector<mojom::MeldFiatCurrencyPtr> expected;
  expected.push_back(mojom::MeldFiatCurrency::New(
      "AFN", std::nullopt,
      "https://images-currency.meld.io/fiat/AFN/symbol.png"));
  expected.push_back(mojom::MeldFiatCurrency::New(
      "DZD", "Algerian Dinar",
      "https://images-currency.meld.io/fiat/DZD/symbol.png"));
  EXPECT_EQ(*fiat_currencies, expected);

  // A bare list is not a valid response anymore.
  std::tie(fiat_currencies, errors) = TestGetFiatCurrencies(R"([{
    "currencyCode": "AFN",
    "name": null,
    "symbol": "https://images-currency.meld.io/fiat/AFN/symbol.png"
  }])");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  // `currencyCode` is a required field.
  std::tie(fiat_currencies, errors) = TestGetFiatCurrencies(R"({
  "currencies": [
    {
      "name": "Afghani",
      "symbol": "https://images-currency.meld.io/fiat/AFN/symbol.png"
    }
  ]})");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(fiat_currencies, errors) =
      TestGetFiatCurrencies("some wrong data", net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(fiat_currencies, errors) =
      TestGetFiatCurrencies(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                            net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, GetCryptoCurrencies) {
  std::optional<std::vector<mojom::MeldCryptoCurrencyPtr>> crypto_currencies;
  Errors errors;

  const auto url = MeldIntegrationService::GetCryptoCurrenciesURL();

  EXPECT_EQ(url.path(), "/network-partner/supported/currencies");
  EXPECT_THAT(net::UrlSearchParams(url).params(),
              ElementsAre(Pair("category", "CRYPTO_ONRAMP"),  //
                          Pair("type", "CRYPTO")));

  std::tie(crypto_currencies, errors) = TestGetCryptoCurrencies(R"({
  "currencies": [
    {
      "currencyCode": "USDT_POLYGON",
      "name": "Tether",
      "chainCode": "POLYGON",
      "chainId": "137",
      "contract": "0xe41d2489571d322189246dafa5ebde1f4699f498",
      "symbol": "https://images-currency.meld.io/crypto/USDT_POLYGON/symbol.png"
    },
    {
      "currencyCode": "00",
      "name": "00 Token",
      "chainCode": "ETH",
      "chainId": "1",
      "contract": "0x111111111117dc0aa78b770fa6a738034120c302",
      "symbol": "https://images-currency.meld.io/crypto/00/symbol.png"
    }
  ]})");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(crypto_currencies);

  std::vector<mojom::MeldCryptoCurrencyPtr> expected;
  expected.push_back(mojom::MeldCryptoCurrency::New(
      mojom::CoinType::ETH, "0x89", "USDT", "USDT_POLYGON", "Tether", "POLYGON",
      "0xe41d2489571d322189246dafa5ebde1f4699f498",
      "https://images-currency.meld.io/crypto/USDT_POLYGON/symbol.png"));
  expected.push_back(mojom::MeldCryptoCurrency::New(
      mojom::CoinType::ETH, "0x1", "00", "00", "00 Token", "ETH",
      "0x111111111117dc0aa78b770fa6a738034120c302",
      "https://images-currency.meld.io/crypto/00/symbol.png"));
  EXPECT_EQ(*crypto_currencies, expected);

  // A bare list is not a valid response anymore.
  std::tie(crypto_currencies, errors) = TestGetCryptoCurrencies(R"([{
    "currencyCode": "USDT_KCC",
    "name": "Tether",
    "chainCode": "KCC",
    "chainId": "0",
    "contract": "0xe41d2489571d322189246dafa5ebde1f4699f498",
    "symbol": "https://images-currency.meld.io/crypto/USDT_KCC/symbol.png"
  }])");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  // `currencyCode` is a required field.
  std::tie(crypto_currencies, errors) = TestGetCryptoCurrencies(R"({
  "currencies": [
    {
      "name": "Tether",
      "chainCode": "KCC",
      "chainId": "0",
      "contract": "0xe41d2489571d322189246dafa5ebde1f4699f498",
      "symbol": "https://images-currency.meld.io/crypto/USDT_KCC/symbol.png"
    }
  ]})");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(crypto_currencies, errors) =
      TestGetCryptoCurrencies("some wrong data", net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_currencies, errors) =
      TestGetCryptoCurrencies(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                              net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, GetCountries) {
  std::optional<std::vector<mojom::MeldCountryPtr>> countries;
  Errors errors;

  const auto url = MeldIntegrationService::GetCountriesURL();
  EXPECT_EQ(url.path(), "/network-partner/supported/countries");
  EXPECT_THAT(net::UrlSearchParams(url).params(),
              ElementsAre(Pair("category", "CRYPTO_ONRAMP")));
  std::tie(countries, errors) = TestGetCountries(R"({
  "countries": [
    {
      "countryCode": "AF",
      "name": "Afghanistan"
    },
    {
      "countryCode": "AL",
      "name": "Albania"
    }
  ]})");
  EXPECT_FALSE(errors.has_value());
  ASSERT_TRUE(countries);

  std::vector<mojom::MeldCountryPtr> expected;
  expected.push_back(mojom::MeldCountry::New("AF", "Afghanistan"));
  expected.push_back(mojom::MeldCountry::New("AL", "Albania"));
  EXPECT_EQ(*countries, expected);

  // A bare list is not a valid response anymore.
  std::tie(countries, errors) = TestGetCountries(R"([
  {
    "countryCode": "AL",
    "name": "Albania"
  }])");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  // `countryCode` is a required field.
  std::tie(countries, errors) = TestGetCountries(R"({
  "countries": [
    {
      "name": "Albania"
    }
  ]})");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(countries, errors) = TestGetCountries("some wrong data");
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(countries, errors) =
      TestGetCountries("some wrong data", net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(countries, errors) = TestGetCountries(R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
                                                 net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, CryptoBuyWidgetCreate) {
  mojom::MeldCryptoWidgetPtr crypto_widget;
  Errors errors;

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      R"({
  "id": "WXDpzmm2cNmtJWLDHgu1GT",
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", "customer@email", "customer_id", "external_customer_id",
      "external_session_id");
  EXPECT_FALSE(errors.has_value());
  EXPECT_EQ("WXDpzmm2cNmtJWLDHgu1GT", crypto_widget->id);
  EXPECT_EQ("external_customer_id", crypto_widget->external_customer_id);
  EXPECT_EQ("external_session_id", crypto_widget->external_session_id);
  EXPECT_EQ("WXEvEDzSgNedXWnJ55pwUJ", crypto_widget->customer_id);
  EXPECT_EQ("token-val", crypto_widget->token);
  EXPECT_EQ("https://meldcrypto.com?token=token-val",
            crypto_widget->widget_url);

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      R"({
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      "some wrong data", "US", "BTC",
      std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      "some wrong data", "US", "BTC",
      std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      "", "", "", std::nullopt, std::nullopt, std::nullopt, "", "", "", "",
      std::nullopt, std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      net::HTTP_OK, true);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{l10n_util::GetStringUTF8(
                         IDS_WALLET_REQUEST_PROCESSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoBuyWidgetCreate(
      R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, CryptoSellWidgetCreate) {
  mojom::MeldCryptoWidgetPtr crypto_widget;
  Errors errors;

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      R"({
  "id": "WXDpzmm2cNmtJWLDHgu1GT",
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", std::nullopt,
      "walletTag", "customer@email", "customer_id", "external_customer_id",
      "external_session_id");
  EXPECT_FALSE(errors.has_value());
  EXPECT_EQ("WXDpzmm2cNmtJWLDHgu1GT", crypto_widget->id);
  EXPECT_EQ("external_customer_id", crypto_widget->external_customer_id);
  EXPECT_EQ("external_session_id", crypto_widget->external_session_id);
  EXPECT_EQ("WXEvEDzSgNedXWnJ55pwUJ", crypto_widget->customer_id);
  EXPECT_EQ("token-val", crypto_widget->token);
  EXPECT_EQ("https://meldcrypto.com?token=token-val",
            crypto_widget->widget_url);

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      R"({
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      "some wrong data", "US", "BTC",
      std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      "some wrong data", "US", "BTC",
      std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      "", "", "", std::nullopt, std::nullopt, std::nullopt, "", "", "",
      std::nullopt, std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      std::nullopt, net::HTTP_OK, true);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{l10n_util::GetStringUTF8(
                         IDS_WALLET_REQUEST_PROCESSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoSellWidgetCreate(
      R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
      "US", "BTC", std::vector<std::string>{"cryptoCurrency"}, "BANK_TRANSFER",
      "https://sb.fluidmoney.xyz", "AKOYA", "100", "USD", "testWalletAddress",
      "walletTag", std::nullopt, std::nullopt, std::nullopt,
      "external_session_id", net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

TEST_F(MeldIntegrationServiceUnitTest, CryptoTransferWidgetCreate) {
  mojom::MeldCryptoWidgetPtr crypto_widget;
  Errors errors;

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      R"({
  "id": "WXDpzmm2cNmtJWLDHgu1GT",
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "institution", std::vector<std::string>{"cryptoCurrency"},
      "https://sb.fluidmoney.xyz", "AKOYA", "1",
      std::vector<std::string>{"BTC", "ETH"}, std::nullopt, "walletTag",
      "customer@email", "customer_id", "external_customer_id",
      "external_session_id");
  EXPECT_FALSE(errors.has_value());
  EXPECT_EQ("WXDpzmm2cNmtJWLDHgu1GT", crypto_widget->id);
  EXPECT_EQ("external_customer_id", crypto_widget->external_customer_id);
  EXPECT_EQ("external_session_id", crypto_widget->external_session_id);
  EXPECT_EQ("WXEvEDzSgNedXWnJ55pwUJ", crypto_widget->customer_id);
  EXPECT_EQ("token-val", crypto_widget->token);
  EXPECT_EQ("https://meldcrypto.com?token=token-val",
            crypto_widget->widget_url);

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      R"({
  "externalSessionId": "external_session_id",
  "externalCustomerId": "external_customer_id",
  "customerId": "WXEvEDzSgNedXWnJ55pwUJ",
  "widgetUrl": "https://meldcrypto.com?token=token-val",
  "token": "token-val"
  })",
      "US", "institution", std::vector<std::string>{"cryptoCurrency"},
      "https://sb.fluidmoney.xyz", "AKOYA", "1",
      std::vector<std::string>{"BTC", "ETH"}, std::nullopt, "walletTag",
      std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_PARSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      "some wrong data", "US", "institution",
      std::vector<std::string>{"cryptoCurrency"}, "https://sb.fluidmoney.xyz",
      "AKOYA", "1", std::vector<std::string>{"BTC", "ETH"}, std::nullopt,
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      "some wrong data", "US", "institution",
      std::vector<std::string>{"cryptoCurrency"}, "https://sb.fluidmoney.xyz",
      "AKOYA", "1", std::vector<std::string>{"BTC", "ETH"}, std::nullopt,
      "walletTag", std::nullopt, std::nullopt, std::nullopt, std::nullopt,
      net::HTTP_REQUEST_TIMEOUT);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{
                         l10n_util::GetStringUTF8(IDS_WALLET_INTERNAL_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      "", std::nullopt, std::nullopt, std::nullopt, std::nullopt, "", "",
      std::vector<std::string>{}, std::nullopt, std::nullopt, std::nullopt,
      std::nullopt, std::nullopt, std::nullopt, net::HTTP_OK, true);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>{l10n_util::GetStringUTF8(
                         IDS_WALLET_REQUEST_PROCESSING_ERROR)});

  std::tie(crypto_widget, errors) = TestCryptoTransferWidgetCreate(
      R"({
    "code": "BAD_REQUEST",
    "message": "Bad request",
    "errors": [
      "[sourceAmount] must not be null",
      "[sourceCurrencyCode] must not be blank"
    ],
    "requestId": "356dd2b40fa55037bfe9d190b6438f59",
    "timestamp": "2024-04-05T07:54:01.318455Z"
  })",
      "US", "institution", std::vector<std::string>{"cryptoCurrency"},
      "https://sb.fluidmoney.xyz", "AKOYA", "1",
      std::vector<std::string>{"BTC", "ETH"}, std::nullopt, "walletTag",
      "customer@email", "customer_id", "external_customer_id",
      "external_session_id", net::HTTP_BAD_REQUEST);
  EXPECT_TRUE(errors.has_value());
  EXPECT_EQ(*errors, std::vector<std::string>(
                         {"[sourceAmount] must not be null",
                          "[sourceCurrencyCode] must not be blank"}));
}

}  // namespace brave_wallet
