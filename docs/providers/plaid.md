> [!WARNING]
> Plaid integration currently only works for Western users. Plaid Production support is not available to European users.

> [!NOTE]
> For Plaid integration your Sure instance needs to be accessible by the internet behind a domain with working SSL.
> See additional context in [maybe-finance/maybe#2419](https://github.com/maybe-finance/maybe/pull/2419).

# Setting Up Plaid

## 1. Create Your Plaid Account

Go to [https://dashboard.plaid.com](https://dashboard.plaid.com) and register for a new account.

---

## 2. Requesting Access Based on Your Bank Type

### For Banks That **Do Not Require OAuth**

1. On the Home page, find the section labeled "Learn how to build with Plaid" and click **Unlock real data**.
2. Enter your real name and phone number.
3. In the description box, write a statement such as:  
   This is for personal use only on a self-hosted version of the Sure Finance software. I am only using it to manage my finances, sync my bank accounts, track my spending, and create a budget.
4. Leave the "Additional products" section **unchecked**.
5. Click **Request Access**.
6. Wait for your request to be approved (this may take more than 24 hours).

---

### For Banks That **Require OAuth**

> [!NOTE]
> Per Plaid Support as of July 2025, certain banks are seeing extended OAuth approval timelines.
> - Chase Bank: there have been some additional delays, resulting in an updated wait time of roughly 3-4 months
> - Schwab: the manual review process by Schwab can take up to two months to be completed

1. In the left sidebar on the Plaid dashboard, click **Get production access**.
2. Enter your real address.
3. For the business profile, write:  
   This is for personal use only on a self-hosted version of the Sure Finance software. I am only using it to manage my finances, sync my bank accounts, track my spending, and create a budget.
4. Leave the company website field **blank**.
5. Enter your real name, phone number, email address, and date of birth.
6. Click **Next**.
7. Indicate that you have 0 employees, specify your country of data access, confirm that you do not sell data, and confirm that you have not experienced a security breach in the past 12 months.
8. Click **Next**.
9. When asked "What industry are you in?", select **Budgeting and financial management tools**.
10. Click **Next**.
11. Enter any name for your application.
12. Upload any photo as the logo (must be 1024x1024px and under 4MB).
13. Leave the brand color as **#22CCEE**.
14. Set the Website URL to:  
    https://github.com/we-promise/sure
15. In the "Reason for data access" box, enter:  
    This is for personal use only on a self-hosted version of the Sure Finance software. I am only using it to manage my finances, sync my bank accounts, track my spending, and create a budget.
16. Enter your real email address as the support email.
17. Click **Next**.
18. For the "Where do you want to launch?" section, enter your country.
19. - In the "Payments" section, check only **Auth** and **Balance**. Leave the rest unchecked.
    - Leave all products in "Credit Underwriting" and "Fraud & Compliance" **unchecked**.
    - Check **all products** under the "Financial Management" section.
20. Click **Next**.
21. For use cases:
    - Select **Consumer bill pay** for the Payments section.
    - Select **Personal budgeting and financial advice** for all products in the Financial Management section.
22. Click **Next**.
23. Select the **Pay As You Go** plan.
24. Click **Next**.
25. Enter your billing details and check the agreement boxes.
26. Click **Next**.
27. Click **Start Security Practices Questionnaire**.
28. For each question, select **Other - please see comments**, then write in the notes:  
    This is for personal use only on a self-hosted version of the Sure Finance software. I am only using it to manage my finances, sync my bank accounts, track my spending, and create a budget.
29. Click **Next**.
30. Repeat the process from step 28 for each new section of the questionnaire.
31. Continue clicking **Next** and repeating step 28 until the questionnaire is finished.
32. Click **Submit**.
33. Wait for approval (this may take more than 24 hours).

---

# Setting Up Sure to Use Plaid

1. After your Plaid account is registered, go to [https://dashboard.plaid.com/developers/api](https://dashboard.plaid.com/developers/api) or click **Developers > API** in the sidebar, then click **Configure** next to Allowed redirect URIs.
2. Click **Add new URI**, type your domain, and add `/accounts` at the end (for example: `https://budget.yourdomain.com/accounts`).
3. Click **Save changes**.
4. Go to [https://dashboard.plaid.com/developers/keys](https://dashboard.plaid.com/developers/keys) or click **Developers > Keys** in the sidebar.
5. Copy your `client_id` and `secret` keys. Use the "Production" secret key.
6. In your `docker-compose` file, below the `OPENAI_ACCESS_TOKEN: ${OPENAI_ACCESS_TOKEN}` line, add these lines:
```
PLAID_CLIENT_ID: ${PLAID_CLIENT_ID}
PLAID_SECRET: ${PLAID_SECRET}
PLAID_ENV: ${PLAID_ENV}
```
7. In your `.env` file (next to your `docker-compose` file), add these lines:
```
   PLAID_CLIENT_ID: ENTER_CLIENT_ID_FROM_PLAID_HERE  
   PLAID_SECRET: ENTER_SECRET_KEY_FROM_PLAID_HERE  
   PLAID_ENV: production  # (use 'production' for Full/Limited Production Access, or 'sandbox' for Sandbox Access)
```
8. Restart Sure.

---

Once you access your Sure instance from your domain, you should now see the **Link account** option in the Sure UI.

---

# Controlling Billable Refreshes (Optional)

When Sure syncs a Plaid connection, it asks Plaid to refresh that connection's transactions from the bank first. Depending on your Plaid plan, Plaid may bill for each of those refresh requests. Plaid also refreshes connections on its own schedule, so you can trade a little freshness for fewer billed requests.

Each connection that supports transactions has a **Max update interval for billable refreshes** setting on its card in **Accounts**:

| Setting | Automatic syncs request a refresh |
| --- | --- |
| **Always** (default) | On every sync, exactly as before |
| **Daily** | At most once per calendar day |
| **Weekly** | At most once every 7 days |
| **Monthly** | At most once every 30 days |
| **Never** | Not at all |

A few things to know:

- **Only the refresh request is limited.** Sure still syncs transactions from Plaid on every sync. It just doesn't ask Plaid to go back to the bank each time.
- **Syncs you start yourself always refresh.** Using **Sync all** on the Accounts page, or syncing an account, requests a refresh whatever the interval says. If any connection has a limited interval, **Sync all** asks you to confirm first and names those connections.
- **Scheduled and automatic syncs follow the interval.** That covers the nightly sync, the sync that runs when you sign in, and **Sync all** on the Providers settings page.
- **Intervals count calendar days.** A "Daily" connection refreshes once per day even if the nightly sync fires a few seconds earlier than it did the night before.
- **"Never" relies on Plaid's own schedule.** If your instance cannot receive Plaid webhooks, new transactions may show up later than you expect. Pick a longer interval rather than "Never" if freshness matters.

To see what you are being billed for, check your Plaid dashboard's transactions refresh usage.
