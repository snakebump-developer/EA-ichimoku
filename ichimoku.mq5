//+------------------------------------------------------------------+
//|                                                   IchimokuEA.mq5 |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Ichimoku EA"
#property version   "2.10"
#property strict

// Input parameters
input int Tenkan_period = 9;       // Periodo Tenkan-sen
input int Kijun_period = 26;       // Periodo Kijun-sen
input int Senkou_SpanB_period = 52; // Periodo Senkou Span B
input double LotSize = 0.01;       // Dimensione lotto
input int MagicNumber = 123456;    // Numero magico
input int BarsToCheckCloudExit = 3; // Candele da controllare per uscita cloud
input double DailyProfitTarget = 10.0; // Target giornaliero per fermare il trading
input bool EnablePushNotifications = true; // Abilita notifiche push
input int MA_Period = 70;          // Periodo Media Mobile (default: 70)
input double MaxProfitThreshold = 150.0; // Soglia massimo profitto per attivare protezione (default: 150€)
input double ProtectionLevel = 60.0; // Livello di protezione profitto (default: 60€)

// Global variables
int ichimoku_handle_m5;
int ichimoku_handle_m15;
int ichimoku_handle_h1;

int ma_handle_m5;
int ma_handle_m15;
int ma_handle_h1;

double senkou_spanA_buffer_m5[];
double senkou_spanB_buffer_m5[];
double senkou_spanA_buffer_m15[];
double senkou_spanB_buffer_m15[];
double senkou_spanA_buffer_h1[];
double senkou_spanB_buffer_h1[];

double tenkan_buffer_h1[];
double kijun_buffer_h1[];

double ma_buffer_m5[];
double ma_buffer_m15[];
double ma_buffer_h1[];

bool stop_trading_today = false;

// Profit tracking
double daily_profit = 0;
double total_profit = 0;
datetime last_calculation_date = 0;
double daily_profit_offset = 0;

// Candle control variables
datetime last_trade_candle_time = 0;
datetime last_close_candle_time = 0;

// H1 candle monitoring
datetime entry_h1_candle_time = 0;  // Tempo della candela H1 di apertura
bool entry_h1_candle_closed = false; // Se la candela H1 di entrata si è chiusa
double max_profit_after_h1_close = 0; // Massimo profitto raggiunto dopo chiusura candela H1
bool protection_activated = false;    // Se la protezione profitto è attivata

//+------------------------------------------------------------------+
//| Send push notification                                           |
//+------------------------------------------------------------------+
void SendPushNotif(string message)
{
   if(EnablePushNotifications)
   {
      if(!SendNotification(message))
      {
         Print("⚠️ Errore invio notifica push: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Get current H1 candle time                                       |
//+------------------------------------------------------------------+
datetime GetCurrentH1CandleTime()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_H1, 0, 1, rates) > 0)
   {
      return rates[0].time;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   ichimoku_handle_m5 = iIchimoku(_Symbol, PERIOD_M5, Tenkan_period, Kijun_period, Senkou_SpanB_period);
   ichimoku_handle_m15 = iIchimoku(_Symbol, PERIOD_M15, Tenkan_period, Kijun_period, Senkou_SpanB_period);
   ichimoku_handle_h1 = iIchimoku(_Symbol, PERIOD_H1, Tenkan_period, Kijun_period, Senkou_SpanB_period);
   
   ma_handle_m5 = iMA(_Symbol, PERIOD_M5, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
   ma_handle_m15 = iMA(_Symbol, PERIOD_M15, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
   ma_handle_h1 = iMA(_Symbol, PERIOD_H1, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
   
   if(ichimoku_handle_m5 == INVALID_HANDLE || ichimoku_handle_m15 == INVALID_HANDLE || ichimoku_handle_h1 == INVALID_HANDLE)
   {
      Print("Errore creazione indicatori Ichimoku");
      return(INIT_FAILED);
   }
   
   if(ma_handle_m5 == INVALID_HANDLE || ma_handle_m15 == INVALID_HANDLE || ma_handle_h1 == INVALID_HANDLE)
   {
      Print("Errore creazione indicatori Media Mobile");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(senkou_spanA_buffer_m5, true);
   ArraySetAsSeries(senkou_spanB_buffer_m5, true);
   ArraySetAsSeries(senkou_spanA_buffer_m15, true);
   ArraySetAsSeries(senkou_spanB_buffer_m15, true);
   ArraySetAsSeries(senkou_spanA_buffer_h1, true);
   ArraySetAsSeries(senkou_spanB_buffer_h1, true);
   
   ArraySetAsSeries(tenkan_buffer_h1, true);
   ArraySetAsSeries(kijun_buffer_h1, true);
   
   ArraySetAsSeries(ma_buffer_m5, true);
   ArraySetAsSeries(ma_buffer_m15, true);
   ArraySetAsSeries(ma_buffer_h1, true);
   
   CalculateProfits();
   
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   
   Print("========================================");
   Print("=== Ichimoku EA - XAUUSD (M5/M15/H1) ===");
   Print("========================================");
   Print("Simbolo: ", _Symbol);
   Print("Modalità riempimento: ", GetFillingMode());
   Print("REGOLE ENTRATA:");
   Print("  1. Tutti e 3 i timeframe (M5+M15+H1) devono concordare");
   Print("  2. Il prezzo H1 deve essere APPENA uscito dalla nuvola");
   Print("     (nelle ultime ", BarsToCheckCloudExit, " candele)");
   Print("  3. Nessuna rientrata sulla stessa candela dopo chiusura");
   Print("USCITA: Prezzo incrocia MA(", MA_Period, ") H1");
   Print("Stop Loss: Tenkan-sen H1");
   Print("PROTEZIONE PROFITTO:");
   Print("  - Se dopo chiusura candela H1 entrata raggiunge €", MaxProfitThreshold);
   Print("  - Chiude se ritraccia sotto €", ProtectionLevel);
   Print("Media Mobile: ", MA_Period, " periodi");
   Print("TARGET GIORNALIERO: $", DoubleToString(DailyProfitTarget, 2), " → Stop trading");
   Print("Notifiche Push: ", (EnablePushNotifications ? "ABILITATE" : "DISABILITATE"));
   Print("Profitto Giornaliero: $", DoubleToString(daily_profit, 2));
   Print("Profitto Totale: $", DoubleToString(total_profit, 2));
   Print("========================================");
   
   SendPushNotif("🤖 Ichimoku EA Avviato\n" + 
                 _Symbol + " (M5/M15/H1)\n" +
                 "SL: Tenkan-sen H1\n" +
                 "Protezione: €" + DoubleToString(MaxProfitThreshold, 0) + " → €" + DoubleToString(ProtectionLevel, 0) + "\n" +
                 "Oggi: $" + DoubleToString(daily_profit, 2));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ichimoku_handle_m5 != INVALID_HANDLE)
      IndicatorRelease(ichimoku_handle_m5);
   if(ichimoku_handle_m15 != INVALID_HANDLE)
      IndicatorRelease(ichimoku_handle_m15);
   if(ichimoku_handle_h1 != INVALID_HANDLE)
      IndicatorRelease(ichimoku_handle_h1);
      
   if(ma_handle_m5 != INVALID_HANDLE)
      IndicatorRelease(ma_handle_m5);
   if(ma_handle_m15 != INVALID_HANDLE)
      IndicatorRelease(ma_handle_m15);
   if(ma_handle_h1 != INVALID_HANDLE)
      IndicatorRelease(ma_handle_h1);
   
   ObjectsDeleteAll(0, "Info_");
   ObjectsDeleteAll(0, "Profit_");
   ObjectsDeleteAll(0, "SL_Line");
   ObjectsDeleteAll(0, "MA_Line");
   ObjectsDeleteAll(0, "Tenkan_Line");
   ObjectsDeleteAll(0, "Protection_Line");
   ObjectsDeleteAll(0, "InfoBG");
   ObjectsDeleteAll(0, "ResetButton");
   ChartRedraw();
   
   Print("========================================");
   Print("EA Fermato - Risultati Finali:");
   Print("Profitto Giornaliero: $", DoubleToString(daily_profit, 2));
   Print("Profitto Totale: $", DoubleToString(total_profit, 2));
   Print("========================================");
   
   SendPushNotif("🛑 Ichimoku EA Fermato\n" + 
                 "Oggi: $" + DoubleToString(daily_profit, 2) + "\n" +
                 "Totale: $" + DoubleToString(total_profit, 2));
}

//+------------------------------------------------------------------+
//| Get filling mode for the symbol                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   else if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   else
      return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Get current M5 candle open time                                  |
//+------------------------------------------------------------------+
datetime GetCurrentCandleTime()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_M5, 0, 1, rates) > 0)
   {
      return rates[0].time;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if we can trade on current candle                          |
//+------------------------------------------------------------------+
bool CanTradeOnCurrentCandle()
{
   datetime current_candle_time = GetCurrentCandleTime();
   
   if(current_candle_time == 0)
   {
      Print("⚠️ Impossibile ottenere il tempo della candela corrente");
      return false;
   }
   
   if(last_close_candle_time == current_candle_time)
   {
      Print("⚠️ Trade bloccato: Posizione chiusa su questa candela alle ", TimeToString(last_close_candle_time, TIME_DATE|TIME_MINUTES));
      Print("   In attesa della prossima candela...");
      return false;
   }
   
   if(last_trade_candle_time == current_candle_time)
   {
      Print("⚠️ Trade bloccato: Già tradato su questa candela alle ", TimeToString(last_trade_candle_time, TIME_DATE|TIME_MINUTES));
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "ResetButton")
      {
         ResetDailyProfit();
         ObjectSetInteger(0, "ResetButton", OBJPROP_STATE, false);
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| Reset daily profit to zero                                       |
//+------------------------------------------------------------------+
void ResetDailyProfit()
{
   datetime current_date = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(current_date, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today_start = StructToTime(dt);
   
   double actual_daily = 0;
   
   HistorySelect(0, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   
   for(int i = 0; i < total_deals; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket > 0)
      {
         if(HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) == MagicNumber)
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            {
               datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
               if(deal_time >= today_start)
               {
                  double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
                  double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
                  double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
                  actual_daily += profit + commission + swap;
               }
            }
         }
      }
   }
   
   daily_profit_offset = -actual_daily;
   stop_trading_today = false;
   
   CalculateProfits();
   
   Print("========================================");
   Print("📊 RESET PROFITTO GIORNALIERO");
   Print("Profitto precedente: $", DoubleToString(actual_daily, 2));
   Print("Nuovo profitto: $", DoubleToString(daily_profit, 2));
   Print("Trading ripreso");
   Print("========================================");
   
   SendPushNotif("🔄 Reset Profitto Giornaliero\n" + 
                 "Precedente: $" + DoubleToString(actual_daily, 2) + "\n" +
                 "Nuovo: $" + DoubleToString(daily_profit, 2));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(CopyBuffer(ichimoku_handle_m5, 2, 0, 3, senkou_spanA_buffer_m5) <= 0) return;
   if(CopyBuffer(ichimoku_handle_m5, 3, 0, 3, senkou_spanB_buffer_m5) <= 0) return;
   
   if(CopyBuffer(ichimoku_handle_m15, 2, 0, 3, senkou_spanA_buffer_m15) <= 0) return;
   if(CopyBuffer(ichimoku_handle_m15, 3, 0, 3, senkou_spanB_buffer_m15) <= 0) return;
   
   if(CopyBuffer(ichimoku_handle_h1, 2, 0, BarsToCheckCloudExit + 2, senkou_spanA_buffer_h1) <= 0) return;
   if(CopyBuffer(ichimoku_handle_h1, 3, 0, BarsToCheckCloudExit + 2, senkou_spanB_buffer_h1) <= 0) return;
   
   if(CopyBuffer(ichimoku_handle_h1, 0, 0, 3, tenkan_buffer_h1) <= 0) return;
   if(CopyBuffer(ichimoku_handle_h1, 1, 0, 3, kijun_buffer_h1) <= 0) return;
   
   if(CopyBuffer(ma_handle_m5, 0, 0, 3, ma_buffer_m5) <= 0) return;
   if(CopyBuffer(ma_handle_m15, 0, 0, 3, ma_buffer_m15) <= 0) return;
   if(CopyBuffer(ma_handle_h1, 0, 0, 3, ma_buffer_h1) <= 0) return;
   
   CalculateProfits();
   CheckNewDay();
   
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   int signal_m5 = GetSignal(current_price, senkou_spanA_buffer_m5[1], senkou_spanB_buffer_m5[1]);
   int signal_m15 = GetSignal(current_price, senkou_spanA_buffer_m15[1], senkou_spanB_buffer_m15[1]);
   int signal_h1 = GetSignal(current_price, senkou_spanA_buffer_h1[1], senkou_spanB_buffer_h1[1]);
   
   DisplayInfo(current_price, signal_m5, signal_m15, signal_h1);
   
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         // Check H1 candle monitoring and profit protection
         CheckH1CandleAndProtection();
         
         // Check MA crossing
         CheckMACrossing();
         
         if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            UpdateLines();
         }
         else
         {
            // Position closed, reset variables
            entry_h1_candle_time = 0;
            entry_h1_candle_closed = false;
            max_profit_after_h1_close = 0;
            protection_activated = false;
            
            ObjectDelete(0, "SL_Line");
            ObjectDelete(0, "MA_Line");
            ObjectDelete(0, "Tenkan_Line");
            ObjectDelete(0, "Protection_Line");
         }
      }
   }
   else
   {
      // No position, reset and remove lines
      entry_h1_candle_time = 0;
      entry_h1_candle_closed = false;
      max_profit_after_h1_close = 0;
      protection_activated = false;
      
      ObjectDelete(0, "SL_Line");
      ObjectDelete(0, "MA_Line");
      ObjectDelete(0, "Tenkan_Line");
      ObjectDelete(0, "Protection_Line");
      
      if(!stop_trading_today)
      {
         CheckAndTrade(signal_m5, signal_m15, signal_h1, current_price);
      }
   }
}

//+------------------------------------------------------------------+
//| Check H1 candle and profit protection                            |
//+------------------------------------------------------------------+
void CheckH1CandleAndProtection()
{
   if(!PositionSelect(_Symbol))
      return;
      
   if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return;
   
   double current_profit = PositionGetDouble(POSITION_PROFIT);
   double current_swap = PositionGetDouble(POSITION_SWAP);
   double net_profit = current_profit + current_swap;
   
   datetime current_h1_candle = GetCurrentH1CandleTime();
   
   // Check if entry H1 candle has closed
   if(!entry_h1_candle_closed && current_h1_candle != entry_h1_candle_time)
   {
      entry_h1_candle_closed = true;
      Print("✅ Candela H1 di entrata chiusa. Monitoraggio profitto attivato.");
      Print("   Candela entrata: ", TimeToString(entry_h1_candle_time, TIME_DATE|TIME_MINUTES));
      Print("   Nuova candela: ", TimeToString(current_h1_candle, TIME_DATE|TIME_MINUTES));
   }
   
   // If entry candle has closed, monitor profit
   if(entry_h1_candle_closed)
   {
      // Track maximum profit after H1 candle close
      if(net_profit > max_profit_after_h1_close)
      {
         max_profit_after_h1_close = net_profit;
         
         // Check if protection should be activated
         if(!protection_activated && max_profit_after_h1_close >= MaxProfitThreshold)
         {
            protection_activated = true;
            Print("========================================");
            Print("🛡️ PROTEZIONE PROFITTO ATTIVATA");
            Print("Profitto massimo raggiunto: €", DoubleToString(max_profit_after_h1_close, 2));
            Print("Livello protezione: €", DoubleToString(ProtectionLevel, 2));
            Print("========================================");
            
            SendPushNotif("🛡️ Protezione Attivata\n" + 
                          "Max: €" + DoubleToString(max_profit_after_h1_close, 2) + "\n" +
                          "Chiude se < €" + DoubleToString(ProtectionLevel, 2));
         }
      }
      
      // If protection is activated, check if profit dropped below protection level
      if(protection_activated && net_profit <= ProtectionLevel)
      {
         ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         string type_str = (pos_type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         last_close_candle_time = GetCurrentCandleTime();
         
         ClosePosition("PROTEZIONE PROFITTO", net_profit);
         
         Print("========================================");
         Print("🔴 POSIZIONE CHIUSA: PROTEZIONE PROFITTO");
         Print("Tipo: ", type_str);
         Print("Entrata: ", open_price);
         Print("Uscita: ", current_price);
         Print("Profitto massimo: €", DoubleToString(max_profit_after_h1_close, 2));
         Print("Chiuso a: €", DoubleToString(net_profit, 2));
         Print("Livello protezione: €", DoubleToString(ProtectionLevel, 2));
         Print("========================================");
         
         SendPushNotif("🔴 Protezione Profitto\n" + 
                       type_str + " Chiuso\n" +
                       "Max: €" + DoubleToString(max_profit_after_h1_close, 2) + "\n" +
                       "Chiuso: €" + DoubleToString(net_profit, 2) + "\n" +
                       "Oggi: $" + DoubleToString(daily_profit, 2));
         
         if(net_profit >= DailyProfitTarget)
         {
            stop_trading_today = true;
            Print("========================================");
            Print("🎯 TARGET GIORNALIERO RAGGIUNTO: €", DoubleToString(net_profit, 2));
            Print("🛑 NESSUN ALTRO TRADE OGGI");
            Print("========================================");
            
            SendPushNotif("🎯 Target Giornaliero Raggiunto!\n" + 
                          "Profitto: €" + DoubleToString(net_profit, 2) + "\n" +
                          "Trading fermato per oggi");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if new day and reset daily limit                           |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime current_date = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(current_date, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today_start = StructToTime(dt);
   
   if(today_start != last_calculation_date && last_calculation_date != 0)
   {
      stop_trading_today = false;
      daily_profit_offset = 0;
      last_trade_candle_time = 0;
      last_close_candle_time = 0;
      Print("🌅 NUOVO GIORNO - Trading ripreso - Reset profitto giornaliero");
      
      SendPushNotif("🌅 Nuovo Giorno Iniziato\n" + 
                    _Symbol + " | Trading ripreso");
   }
}

//+------------------------------------------------------------------+
//| Check if price just exited cloud on H1                           |
//+------------------------------------------------------------------+
bool JustExitedCloud(int direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_H1, 0, BarsToCheckCloudExit + 2, rates) <= 0)
   {
      Print("⚠️ Errore nel copiare candele H1 per controllo uscita cloud");
      return false;
   }
   
   double current_close = rates[1].close;
   int current_signal = GetSignal(current_close, senkou_spanA_buffer_h1[1], senkou_spanB_buffer_h1[1]);
   
   if(current_signal != direction)
   {
      return false;
   }
   
   bool found_cloud_position = false;
   
   for(int i = 2; i <= BarsToCheckCloudExit + 1; i++)
   {
      double bar_close = rates[i].close;
      int bar_signal = GetSignal(bar_close, senkou_spanA_buffer_h1[i], senkou_spanB_buffer_h1[i]);
      
      if(bar_signal == 0)
      {
         found_cloud_position = true;
         Print("✅ Uscita cloud confermata su H1: Candela ", i, " era dentro la nuvola");
         break;
      }
   }
   
   if(found_cloud_position)
   {
      Print("✅ USCITA FRESCA DALLA NUVOLA rilevata su H1 - Trade consentito");
      return true;
   }
   else
   {
      Print("⚠️ Prezzo già lontano dalla nuvola su H1 - Nessuna uscita recente nelle ultime ", BarsToCheckCloudExit, " candele");
      return false;
   }
}

//+------------------------------------------------------------------+
//| Check if price crossed H1 MA and close position                  |
//+------------------------------------------------------------------+
void CheckMACrossing()
{
   if(!PositionSelect(_Symbol))
      return;
      
   if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return;
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double h1_ma = ma_buffer_h1[0];
   
   bool should_close = false;
   string close_reason = "";
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      if(current_price < h1_ma)
      {
         should_close = true;
         close_reason = "Prezzo incrocio sotto MA(" + IntegerToString(MA_Period) + ") H1";
      }
   }
   else
   {
      if(current_price > h1_ma)
      {
         should_close = true;
         close_reason = "Prezzo incrocio sopra MA(" + IntegerToString(MA_Period) + ") H1";
      }
   }
   
   if(should_close)
   {
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      double total_profit_close = profit + swap;
      string type_str = (pos_type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      
      last_close_candle_time = GetCurrentCandleTime();
      
      ClosePosition("INCROCIO MA", total_profit_close);
      
      Print("========================================");
      Print("🔴 POSIZIONE CHIUSA: INCROCIO MA");
      Print("Tipo: ", type_str);
      Print("Entrata: ", open_price);
      Print("Uscita: ", current_price);
      Print("MA H1: ", h1_ma);
      Print("Profitto: €", DoubleToString(total_profit_close, 2));
      Print("Motivo: ", close_reason);
      Print("========================================");
      
      SendPushNotif("🔴 Incrocio MA H1\n" + 
                    type_str + " Chiuso | P/L: €" + DoubleToString(total_profit_close, 2) + "\n" +
                    "Oggi: $" + DoubleToString(daily_profit, 2));
      
      if(total_profit_close >= DailyProfitTarget)
      {
         stop_trading_today = true;
         Print("========================================");
         Print("🎯 TARGET GIORNALIERO RAGGIUNTO: €", DoubleToString(total_profit_close, 2));
         Print("🛑 NESSUN ALTRO TRADE OGGI");
         Print("========================================");
         
         SendPushNotif("🎯 Target Giornaliero Raggiunto!\n" + 
                       "Profitto: €" + DoubleToString(total_profit_close, 2) + "\n" +
                       "Trading fermato per oggi");
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate daily and total profits                                |
//+------------------------------------------------------------------+
void CalculateProfits()
{
   datetime current_date = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(current_date, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today_start = StructToTime(dt);
   
   if(today_start != last_calculation_date)
   {
      last_calculation_date = today_start;
   }
   
   daily_profit = 0;
   total_profit = 0;
   
   HistorySelect(0, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   
   for(int i = 0; i < total_deals; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket > 0)
      {
         if(HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) == MagicNumber)
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            {
               double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
               double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
               double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
               
               double net_profit = profit + commission + swap;
               
               total_profit += net_profit;
               
               datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
               if(deal_time >= today_start)
               {
                  daily_profit += net_profit;
               }
            }
         }
      }
   }
   
   daily_profit += daily_profit_offset;
   
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         double current_profit = PositionGetDouble(POSITION_PROFIT);
         double current_swap = PositionGetDouble(POSITION_SWAP);
         double floating_profit = current_profit + current_swap;
         
         daily_profit += floating_profit;
         total_profit += floating_profit;
      }
   }
}

//+------------------------------------------------------------------+
//| Get signal based on price and cloud                              |
//+------------------------------------------------------------------+
int GetSignal(double price, double spanA, double spanB)
{
   double cloud_top = MathMax(spanA, spanB);
   double cloud_bottom = MathMin(spanA, spanB);
   
   if(price > cloud_top)
      return 1;
   else if(price < cloud_bottom)
      return -1;
   else
      return 0;
}

//+------------------------------------------------------------------+
//| Get pip value for the current symbol                             |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   
   if(StringFind(symbol, "JPY") >= 0)
      return 0.01;
   else if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.1;
   else
      return 0.0001;
}

//+------------------------------------------------------------------+
//| Update visual lines on chart                                     |
//+------------------------------------------------------------------+
void UpdateLines()
{
   if(!PositionSelect(_Symbol))
      return;
      
   double sl_price = PositionGetDouble(POSITION_SL);
   
   if(sl_price > 0)
   {
      string sl_label = "Stop Loss (Tenkan H1): " + DoubleToString(sl_price, _Digits);
      DrawHorizontalLine("SL_Line", sl_price, clrRed, STYLE_SOLID, 2, sl_label);
   }
   
   double h1_tenkan = tenkan_buffer_h1[0];
   string tenkan_label = "Tenkan-sen H1: " + DoubleToString(h1_tenkan, _Digits);
   DrawHorizontalLine("Tenkan_Line", h1_tenkan, clrOrange, STYLE_DOT, 1, tenkan_label);
   
   double h1_ma = ma_buffer_h1[0];
   string ma_label = "MA H1(" + IntegerToString(MA_Period) + "): " + DoubleToString(h1_ma, _Digits);
   DrawHorizontalLine("MA_Line", h1_ma, clrBlue, STYLE_DASH, 2, ma_label);
   
   // Draw protection level line if active
   if(protection_activated)
   {
      double current_profit = PositionGetDouble(POSITION_PROFIT);
      double current_swap = PositionGetDouble(POSITION_SWAP);
      double net_profit = current_profit + current_swap;
      
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      
      // Calculate approximate price for protection level
      double protection_price;
      double pip_value = GetPipValue();
      double protection_pips = ProtectionLevel * 10.0 / LotSize; // Approximate
      
      if(pos_type == POSITION_TYPE_BUY)
         protection_price = open_price + (protection_pips * pip_value);
      else
         protection_price = open_price - (protection_pips * pip_value);
      
      string protection_label = "Protezione (€" + DoubleToString(ProtectionLevel, 0) + "): " + DoubleToString(protection_price, _Digits);
      DrawHorizontalLine("Protection_Line", protection_price, clrYellow, STYLE_SOLID, 2, protection_label);
   }
}

//+------------------------------------------------------------------+
//| Draw horizontal line on chart                                    |
//+------------------------------------------------------------------+
void DrawHorizontalLine(string name, double price, color line_color, int line_style, int width, string tooltip)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   }
   
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
   ObjectSetInteger(0, name, OBJPROP_STYLE, line_style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
//| Close the current position                                       |
//+------------------------------------------------------------------+
void ClosePosition(string reason, double profit_amount)
{
   if(!PositionSelect(_Symbol))
      return;
      
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   ulong position_ticket = PositionGetInteger(POSITION_TICKET);
   double volume = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   double close_price;
   ENUM_ORDER_TYPE close_type;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      close_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      close_type = ORDER_TYPE_SELL;
   }
   else
   {
      close_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      close_type = ORDER_TYPE_BUY;
   }
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = volume;
   request.type = close_type;
   request.position = position_ticket;
   request.price = close_price;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "Ichimoku EA - " + reason;
   request.type_filling = GetFillingMode();
   
   if(!OrderSend(request, result))
   {
      Print("❌ ERRORE CHIUSURA: ", GetLastError(), " | Codice: ", result.retcode, " | Commento: ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Check and execute trades                                         |
//+------------------------------------------------------------------+
void CheckAndTrade(int signal_m5, int signal_m15, int signal_h1, double current_price)
{
   if(!CanTradeOnCurrentCandle())
   {
      return;
   }
   
   if(signal_m5 == 1 && signal_m15 == 1 && signal_h1 == 1)
   {
      if(JustExitedCloud(1))
      {
         OpenPosition(ORDER_TYPE_BUY);
      }
      else
      {
         Print("⚠️ Segnale BUY ignorato - Prezzo non fresco fuori dalla nuvola su H1");
      }
   }
   else if(signal_m5 == -1 && signal_m15 == -1 && signal_h1 == -1)
   {
      if(JustExitedCloud(-1))
      {
         OpenPosition(ORDER_TYPE_SELL);
      }
      else
      {
         Print("⚠️ Segnale SELL ignorato - Prezzo non fresco fuori dalla nuvola su H1");
      }
   }
}

//+------------------------------------------------------------------+
//| Open a position                                                   |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE order_type)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("❌ Trading non consentito nel terminale");
      return;
   }
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("❌ Trading automatico non consentito");
      return;
   }
   
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   double price, sl_price;
   
   if(order_type == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   
   double h1_tenkan = tenkan_buffer_h1[0];
   sl_price = h1_tenkan;
   
   long stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_distance = stop_level * _Point;
   
   if(MathAbs(price - sl_price) < min_stop_distance)
   {
      if(order_type == ORDER_TYPE_BUY)
         sl_price = price - min_stop_distance - (2 * _Point);
      else
         sl_price = price + min_stop_distance + (2 * _Point);
         
      Print("⚠️ SL aggiustato per rispettare il livello stop del broker: ", sl_price);
   }
   
   double sl_distance = MathAbs(price - sl_price);
   double pip_value = GetPipValue();
   double sl_pips = sl_distance / pip_value;
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = order_type;
   request.price = NormalizeDouble(price, _Digits);
   request.sl = NormalizeDouble(sl_price, _Digits);
   request.tp = 0;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "Ichimoku EA";
   request.type_filling = GetFillingMode();
   
   if(!OrderSend(request, result))
   {
      Print("❌ ERRORE APERTURA: ", GetLastError());
      Print("   Codice: ", result.retcode);
      Print("   Commento: ", result.comment);
   }
   else
   {
      last_trade_candle_time = GetCurrentCandleTime();
      
      // Initialize H1 candle monitoring
      entry_h1_candle_time = GetCurrentH1CandleTime();
      entry_h1_candle_closed = false;
      max_profit_after_h1_close = 0;
      protection_activated = false;
      
      string type_str = (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      
      Print("========================================");
      Print("🟢 POSIZIONE APERTA: ", type_str);
      Print("Entrata: ", price);
      Print("Stop Loss (Tenkan H1): ", sl_price, " (", DoubleToString(sl_pips, 1), " pips)");
      Print("Lotto: ", LotSize);
      Print("M5: ", GetSignalName(GetSignal(price, senkou_spanA_buffer_m5[1], senkou_spanB_buffer_m5[1])));
      Print("M15: ", GetSignalName(GetSignal(price, senkou_spanA_buffer_m15[1], senkou_spanB_buffer_m15[1])));
      Print("H1: ", GetSignalName(GetSignal(price, senkou_spanA_buffer_h1[1], senkou_spanB_buffer_h1[1])));
      Print("USCITA NUVOLA: Breakout fresco rilevato su H1");
      Print("Candela H1 entrata: ", TimeToString(entry_h1_candle_time, TIME_DATE|TIME_MINUTES));
      Print("Protezione: €", MaxProfitThreshold, " → €", ProtectionLevel);
      Print("========================================");
      
      SendPushNotif("🟢 Posizione Aperta\n" + 
                    type_str + " " + _Symbol + " @ " + DoubleToString(price, _Digits) + "\n" +
                    "Lotto: " + DoubleToString(LotSize, 2) + "\n" +
                    "SL (Tenkan H1): " + DoubleToString(sl_price, _Digits) + "\n" +
                    "Protezione: €" + DoubleToString(MaxProfitThreshold, 0) + " → €" + DoubleToString(ProtectionLevel, 0));
   }
}

//+------------------------------------------------------------------+
//| Get signal name as string                                        |
//+------------------------------------------------------------------+
string GetSignalName(int signal)
{
   if(signal == 1) return "BUY";
   else if(signal == -1) return "SELL";
   else return "NELLA NUVOLA";
}

//+------------------------------------------------------------------+
//| Create background rectangle for info panel                       |
//+------------------------------------------------------------------+
void CreateInfoBackground(int x_start, int y_start, int width, int height)
{
   string bg_name = "InfoBG";
   
   if(ObjectFind(0, bg_name) < 0)
   {
      ObjectCreate(0, bg_name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   }
   
   ObjectSetInteger(0, bg_name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, bg_name, OBJPROP_XDISTANCE, x_start);
   ObjectSetInteger(0, bg_name, OBJPROP_YDISTANCE, y_start + height);
   ObjectSetInteger(0, bg_name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg_name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, bg_name, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, bg_name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg_name, OBJPROP_COLOR, clrDarkGray);
   ObjectSetInteger(0, bg_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, bg_name, OBJPROP_BACK, true);
   ObjectSetInteger(0, bg_name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Create reset button                                              |
//+------------------------------------------------------------------+
void CreateResetButton(int x, int y)
{
   string button_name = "ResetButton";
   
   if(ObjectFind(0, button_name) < 0)
   {
      ObjectCreate(0, button_name, OBJ_BUTTON, 0, 0, 0);
   }
   
   ObjectSetInteger(0, button_name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, button_name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, button_name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, button_name, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, button_name, OBJPROP_YSIZE, 25);
   ObjectSetString(0, button_name, OBJPROP_TEXT, "🔄 Reset Oggi");
   ObjectSetString(0, button_name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, button_name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, button_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, button_name, OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, button_name, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, button_name, OBJPROP_BORDER_TYPE, BORDER_RAISED);
   ObjectSetInteger(0, button_name, OBJPROP_STATE, false);
   ObjectSetInteger(0, button_name, OBJPROP_SELECTABLE, true);
}

//+------------------------------------------------------------------+
//| Display information on chart                                      |
//+------------------------------------------------------------------+
void DisplayInfo(double price, int signal_m5, int signal_m15, int signal_h1)
{
   int x = 10;
   int y = 20;
   int line_spacing = 22;
   int current_line = 0;
   
   color text_color = clrWhite;
   int font_size = 9;
   string font_name = "Consolas";
   
   int panel_width = 260;
   int lines_count = 22;
   
   // Add lines for protection info if position is open
   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
   {
      if(entry_h1_candle_closed)
         lines_count += 1;
      if(protection_activated)
         lines_count += 1;
   }
   
   if(stop_trading_today)
      lines_count += 1;
   
   int panel_height = lines_count * line_spacing + 50;
   
   CreateInfoBackground(x - 5, y - 10, panel_width, panel_height);
   
   color daily_color = (daily_profit >= 0) ? clrLime : clrRed;
   color total_color = (total_profit >= 0) ? clrLime : clrRed;
   
   CreateLabel("Profit_0", x, y, 
               "═══ PROFITTI ═══", 
               font_name, font_size, clrGold);
   y += line_spacing;
   
   CreateLabel("Profit_1", x, y, 
               "Oggi:  " + (daily_profit >= 0 ? "+" : "") + DoubleToString(daily_profit, 2) + " $", 
               font_name, font_size + 1, daily_color);
   y += line_spacing;
   
   CreateLabel("Profit_2", x, y, 
               "Totale: " + (total_profit >= 0 ? "+" : "") + DoubleToString(total_profit, 2) + " $", 
               font_name, font_size + 1, total_color);
   y += line_spacing;
   
   double remaining_to_target = DailyProfitTarget - daily_profit;
   color remaining_color;
   string remaining_text;
   
   if(stop_trading_today)
   {
      remaining_text = "Target: RAGGIUNTO!";
      remaining_color = clrGold;
   }
   else if(remaining_to_target > 0)
   {
      remaining_text = "Al target: $" + DoubleToString(remaining_to_target, 2);
      remaining_color = clrOrange;
   }
   else
   {
      remaining_text = "Target: SUPERATO!";
      remaining_color = clrLime;
   }
   
   CreateLabel("Profit_Target", x, y, 
               remaining_text, 
               font_name, font_size, remaining_color);
   y += line_spacing;
   
   // Show protection status if position is open
   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
   {
      if(entry_h1_candle_closed)
      {
         CreateLabel("Profit_H1Status", x, y, 
                     "H1: Monitoraggio attivo", 
                     font_name, font_size, clrCyan);
         y += line_spacing;
      }
      
      if(protection_activated)
      {
         CreateLabel("Profit_Protection", x, y, 
                     "🛡️ Protezione: €" + DoubleToString(ProtectionLevel, 0), 
                     font_name, font_size, clrYellow);
         y += line_spacing;
      }
   }
   else
   {
      // Clean up labels when no position
      ObjectDelete(0, "Profit_H1Status");
      ObjectDelete(0, "Profit_Protection");
   }
   
   CreateResetButton(x, y + 5);
   y += 35;
   
   if(stop_trading_today)
   {
      CreateLabel("Profit_4", x, y, 
                  "🛑 STOP OGGI", 
                  font_name, font_size + 2, clrRed);
      y += line_spacing;
   }
   
   y += 10;
   
   CreateLabel("Info_" + IntegerToString(current_line++), x, y, 
               "═══════ M5 ═══════", 
               font_name, font_size, clrCyan);
   y += line_spacing;
   
   DisplayTimeframeData(x, y, current_line, price, 
                        senkou_spanA_buffer_m5[1], 
                        senkou_spanB_buffer_m5[1],
                        ma_buffer_m5[0],
                        signal_m5,
                        font_name, font_size, text_color);
   current_line += 5;
   y += line_spacing * 5;
   
   y += 8;
   
   CreateLabel("Info_" + IntegerToString(current_line++), x, y, 
               "══════ M15 ══════", 
               font_name, font_size, clrCyan);
   y += line_spacing;
   
   DisplayTimeframeData(x, y, current_line, price, 
                        senkou_spanA_buffer_m15[1], 
                        senkou_spanB_buffer_m15[1],
                        ma_buffer_m15[0],
                        signal_m15,
                        font_name, font_size, text_color);
   current_line += 5;
   y += line_spacing * 5;
   
   y += 8;
   
   CreateLabel("Info_" + IntegerToString(current_line++), x, y, 
               "═══ H1 (USCITA+NUVOLA) ═══", 
               font_name, font_size, clrGold);
   y += line_spacing;
   
   DisplayTimeframeDataH1(x, y, current_line, price, 
                          senkou_spanA_buffer_h1[1], 
                          senkou_spanB_buffer_h1[1],
                          ma_buffer_h1[0],
                          tenkan_buffer_h1[0],
                          signal_h1,
                          font_name, font_size, text_color);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Display data for a specific timeframe                            |
//+------------------------------------------------------------------+
void DisplayTimeframeData(int x, int &y, int &line_counter, double price, 
                         double spanA, double spanB, double ma_value, int signal,
                         string font, int size, color txt_color)
{
   int line_spacing = 22;
   
   string position;
   color position_color;
   
   if(signal == 1)
   {
      position = "BUY";
      position_color = clrLime;
   }
   else if(signal == -1)
   {
      position = "SELL";
      position_color = clrRed;
   }
   else
   {
      position = "NELLA NUVOLA";
      position_color = clrYellow;
   }
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Prezzo:        " + DoubleToString(price, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Senkou Span A: " + DoubleToString(spanA, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Senkou Span B: " + DoubleToString(spanB, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "MA(" + IntegerToString(MA_Period) + "):        " + DoubleToString(ma_value, _Digits), 
               font, size, clrAqua);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               position, 
               font, 11, position_color);
}

//+------------------------------------------------------------------+
//| Display data for H1 timeframe with Tenkan-sen                    |
//+------------------------------------------------------------------+
void DisplayTimeframeDataH1(int x, int &y, int &line_counter, double price, 
                            double spanA, double spanB, double ma_value, double tenkan_value, int signal,
                            string font, int size, color txt_color)
{
   int line_spacing = 22;
   
   string position;
   color position_color;
   
   if(signal == 1)
   {
      position = "BUY";
      position_color = clrLime;
   }
   else if(signal == -1)
   {
      position = "SELL";
      position_color = clrRed;
   }
   else
   {
      position = "NELLA NUVOLA";
      position_color = clrYellow;
   }
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Prezzo:        " + DoubleToString(price, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Senkou Span A: " + DoubleToString(spanA, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Senkou Span B: " + DoubleToString(spanB, _Digits), 
               font, size, txt_color);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "Tenkan-sen:    " + DoubleToString(tenkan_value, _Digits), 
               font, size, clrOrange);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               "MA(" + IntegerToString(MA_Period) + "):        " + DoubleToString(ma_value, _Digits), 
               font, size, clrAqua);
   y += line_spacing;
   
   CreateLabel("Info_" + IntegerToString(line_counter++), x, y, 
               position, 
               font, 11, position_color);
}

//+------------------------------------------------------------------+
//| Create label on chart                                            |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, string font, int size, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   }
   
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}
//+------------------------------------------------------------------+