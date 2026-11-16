
# AI-Powered Personal Expense Tracker

An AI-powered personal finance management mobile application developed using Flutter, Python FastAPI, and PostgreSQL.

The application helps users manage their income, expenses, budgets, savings goals, and financial activities through a user-friendly mobile interface.

It also integrates an AI Financial Assistant Chatbot to provide personalized financial insights and answer questions about users' financial data.

## Tech Stack

- **Frontend:** Flutter, Dart
- **Backend:** Python, FastAPI
- **Database:** PostgreSQL
- **Authentication:** JWT
- **AI Integration:** LLM API
- **API Communication:** REST API
- **Version Control:** Git, GitHub

## Key Features

### 1. User Authentication and Profile Management
- User registration and login
- Secure JWT authentication
- Password reset and password management
- Profile management
- Secure logout
- User-specific financial data access

### 2. Income Management
- Add, edit, and delete income
- Categorize income sources
- View income history
- Filter income by date and category
- Track monthly income

### 3. Expense Management
- Add, edit, and delete expenses
- Categorize expenses
- Search and filter transactions
- Track daily, weekly, and monthly expenses
- View transaction history

### 4. Category Management
- Predefined income and expense categories
- Create custom categories
- Edit and delete custom categories
- Category-wise spending analysis

### 5. Wallet and Account Management
- Manage cash, bank, and digital wallet accounts
- Track account balances
- Transfer money between accounts
- View account transaction history

### 6. Budget Management
- Set monthly budgets
- Create category-wise budgets
- Monitor budget utilization
- Track remaining budgets
- Receive overspending alerts

### 7. Savings Goal Management
- Create savings goals
- Set target amounts and dates
- Record savings contributions
- Monitor savings progress
- Track completed goals

### 8. Financial Dashboard
- Total account balance
- Monthly income and expenses
- Savings overview
- Recent transactions
- Budget progress
- Financial summary charts

### 9. Financial Analytics and Reports
- Daily, weekly, and monthly analysis
- Income vs. expense comparison
- Category-wise expense breakdown
- Spending trend visualization
- PDF and CSV report export

### 10. Bills and Recurring Transactions
- Manage recurring income and expenses
- Track upcoming bills
- Set bill due dates
- Monitor payment status

### 11. Notifications and Alerts
- Budget limit notifications
- Overspending alerts
- Bill payment reminders
- Savings goal notifications

### 12. AI Financial Assistant Chatbot
- Answer questions about income and expenses
- Provide monthly financial summaries
- Identify highest spending categories
- Answer budget-related questions
- Suggest ways to reduce spending
- Provide personalized financial insights
- Support natural-language financial queries

**Example Questions:**
- How much did I spend this month?
- Which category has the highest expenses?
- How much money is left in my budget?
- How can I reduce my monthly expenses?
- Can I save Rs. 10,000 this month?

The chatbot uses an LLM API and user-authorized financial summaries retrieved through the FastAPI backend. No custom machine learning model training is required.

### 13. Settings and Preferences
- Profile settings
- Password management
- Currency preferences
- Light and dark themes
- Notification settings
- Financial data export
- Account deletion

## System Architecture

```text
Flutter Mobile Application
           |
           | REST API
           v
    FastAPI Backend
           |
      +----+----+
      |         |
      v         v
 PostgreSQL   LLM API
 Database     (Chatbot)
```

## Project Structure

```text
AI-Expense-Tracker/
|
|-- frontend/       # Flutter mobile application
|-- backend/        # Python FastAPI backend
|-- README.md       # Project documentation
|-- .gitignore
```

## Development Roadmap

### Phase 1: Project Setup
- [ ] Flutter project setup
- [ ] FastAPI backend setup
- [ ] PostgreSQL database configuration
- [ ] Authentication implementation

### Phase 2: Core Features
- [ ] Income and expense management
- [ ] Category management
- [ ] Wallet and account management
- [ ] Financial dashboard

### Phase 3: Financial Management
- [ ] Budget management
- [ ] Savings goals
- [ ] Analytics and reports
- [ ] Bills and recurring transactions
- [ ] Notifications

### Phase 4: AI Integration
- [ ] AI chatbot interface
- [ ] LLM API integration
- [ ] Secure financial data retrieval
- [ ] Personalized financial responses

### Phase 5: Testing and Deployment
- [ ] Backend API testing
- [ ] Flutter application testing
- [ ] Security testing
- [ ] Backend deployment
- [ ] Android application build

## Security

- Password hashing
- JWT-based authentication
- User-specific database access
- Protected API endpoints
- Secure API key management
- Environment variable configuration
- Restricted financial data access for AI requests

## Project Status

**Status:** In Development

This project is being developed as an individual software development project.

## Future Enhancements

- Bank account integration
- Multi-currency support
- Cloud backup and synchronization
- Advanced financial analytics

## License

License to be determined.
