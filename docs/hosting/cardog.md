# Setting Up Cardog (Vehicle Valuations)

[Cardog](https://cardog.app) provides market data on vehicles listed for sale in the US. Sure can use it to estimate what a vehicle is worth when you add it, and to refresh that estimate every month.

> [!NOTE]
> The estimate is the **median asking price** of live listings for the vehicle's year, make and model. It does not account for mileage, trim or condition, so treat it as a market reference rather than an appraisal. Cardog covers the US market and prices in USD.

## What is sent to Cardog

Only the vehicle's **year, make and model**. Sure never sends your name, VIN, account details or anything else about you. The vehicle's mileage is stored in Sure but is not sent.

## 1. Create a Cardog API key

1. Sign up at [cardog.app](https://cardog.app) and open **Account > API** ([cardog.app/account/api](https://cardog.app/account/api)).
2. Create a key and copy it.

The free tier includes 50 credits per month with no card required. If you reach the allowance, Cardog stops serving requests until the next cycle.

## 2. Add the key to Sure

Either:

- In Sure, go to **Settings > Self-Hosting** and paste the key into the **Cardog** panel under **Vehicle Valuation Providers**, or
- Set it as an environment variable and restart Sure:

```
CARDOG_API_KEY=your_key_here
```

When the environment variable is set, the settings field is disabled and shows that the key is configured through the environment.

## 3. Add a vehicle

1. Add an account and choose **Vehicle**, then **Add via Cardog**.
2. Enter a name, year, make and model (mileage is optional).
3. Review the estimate Sure found. Nothing is created until you confirm.

The vehicle's balance starts at the estimate, and the vehicle is refreshed monthly from then on. Vehicles you add manually are never changed by Cardog.

## Credits and usage

A valuation costs **6 credits**: 1 to match the year, make and model, and 5 for the market quote. Cardog does not charge for requests that fail, and Sure only counts credits for requests that succeeded.

Under **Settings > Self-Hosting**, the Cardog panel shows how many credits you have used this month. After each lookup Sure reads Cardog's own `X-Credits-Allowance` and `X-Credits-Remaining` response headers, so the number includes credits spent elsewhere on the same key and follows your plan's real allowance. Before Sure has made a lookup, it assumes the 50-credit free tier.

To cap Sure's usage below your plan, or to set a limit if Cardog does not report one, set:

```
CARDOG_MAX_REQUESTS_PER_MONTH=100
```

This takes priority over the allowance Cardog reports.

## Monthly refresh

On the 1st of each month, Sure refreshes every vehicle added through Cardog, starting with the one that has gone longest without a refresh. A vehicle is skipped when:

- the account is not active, or it was already refreshed today
- its year, make or model is missing
- its currency is not USD
- there are fewer than 6 credits left this month

Anything skipped is simply tried again the next month, and failures are recorded in the debug log.

## Troubleshooting

**"Cardog rejected the API key"**
The key is wrong or was revoked. Create a new one in Cardog and update it in Sure.

**"Your Cardog account has no credits left"**
You've used this cycle's allowance. Wait for it to reset (Cardog shows the date) or upgrade your plan.

**"Cardog could not find a vehicle matching this year, make and model"**
Check the spelling, or try the common name of the model. Very new, very old or rare models may not have enough listings.

**The usage count looks different from Cardog's dashboard**
Sure updates the count after each lookup. If you used the key elsewhere since, it will catch up the next time Sure makes a request.
