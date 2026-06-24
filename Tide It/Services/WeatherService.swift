import Foundation
import WeatherKit
import CoreLocation
import SwiftUI
import Combine
import os.log

@MainActor
class WeatherService: ObservableObject {
    static let shared = WeatherService()
    private let weatherService = WeatherKit.WeatherService.shared
    
    // Propriétés publiées pour l'UI
    @Published var currentWeather: CurrentWeather?
    @Published var dailyForecast: [DayWeather] = []
    @Published var hourlyForecast: [HourWeather] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // Cache pour les données météo avec expiration
    private var cachedSunriseSunsetTimes: [String: (sunrise: Date?, sunset: Date?, timestamp: Date)] = [:]
    private let cacheExpirationInterval: TimeInterval = 3600 * 12 // 12 heures
    private let maxCacheEntries = 200

    init() {}
    
    /// Récupère les heures de lever et coucher du soleil pour une localisation donnée
    /// - Parameters:
    ///   - location: Coordonnées de la localisation
    ///   - date: Date pour laquelle obtenir les données (par défaut: aujourd'hui)
    /// - Returns: Tuple contenant les heures de lever et coucher du soleil
    func getSunriseSunset(for location: CLLocation, date: Date = Date()) async -> (sunrise: Date?, sunset: Date?) {
        // Génère une clé unique pour cette localisation et cette date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        let cacheKey = "\(location.coordinate.latitude),\(location.coordinate.longitude)_\(dateString)"
        
        // Vérifie si les données sont dans le cache et si elles sont encore valides
        if let cachedData = cachedSunriseSunsetTimes[cacheKey], 
           Date().timeIntervalSince(cachedData.timestamp) < cacheExpirationInterval {
            return (cachedData.sunrise, cachedData.sunset)
        }
        
        // Récupère les données depuis WeatherKit
        do {
            self.errorMessage = nil
            let dailyForecast = try await weatherService.weather(
                for: location,
                including: .daily
            )
            
            // Trouve la prévision pour la date demandée
            let calendar = Calendar.current
            if let forecastForDate = dailyForecast.filter({ calendar.isDate($0.date, inSameDayAs: date) }).first {
                let result = (sunrise: forecastForDate.sun.sunrise, sunset: forecastForDate.sun.sunset)
                
                // Met en cache le résultat avec un timestamp
                cachedSunriseSunsetTimes[cacheKey] = (result.sunrise, result.sunset, Date())
                trimSunCacheIfNeeded()
                return result
            }
            
            return (nil, nil)
        } catch {
            self.errorMessage = "Erreur météo: \(error.localizedDescription)"
            appLogger.error("Erreur lors de la récupération des données météo: \(error)")
            return (nil, nil)
        }
    }
    
    private func trimSunCacheIfNeeded() {
        guard cachedSunriseSunsetTimes.count > maxCacheEntries else { return }
        let sortedKeys = cachedSunriseSunsetTimes
            .sorted { $0.value.timestamp < $1.value.timestamp }
            .map { $0.key }
        
        let overflow = cachedSunriseSunsetTimes.count - maxCacheEntries
        if overflow > 0 {
            for key in sortedKeys.prefix(overflow) {
                cachedSunriseSunsetTimes.removeValue(forKey: key)
            }
        }
    }
    
    /// Récupère les heures de lever et coucher du soleil pour un port donné
    /// - Parameters:
    ///   - port: Port pour lequel obtenir les données
    ///   - date: Date pour laquelle obtenir les données (par défaut: aujourd'hui)
    /// - Returns: Tuple contenant les heures de lever et coucher du soleil
    func getSunriseSunsetForPort(port: Port, date: Date = Date()) async -> (sunrise: Date?, sunset: Date?) {
        let location = port.location
        return await getSunriseSunset(for: location, date: date)
    }

    /// Fetches sunrise/sunset for a date range in a single WeatherKit API call
    func getSunriseSunsetRange(for location: CLLocation, from startDate: Date, days: Int) async -> [(sunrise: Date?, sunset: Date?)] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Check if all days are cached
        var cachedResults: [(sunrise: Date?, sunset: Date?)] = []
        var allCached = true

        for i in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: i, to: startDate) else {
                allCached = false
                break
            }
            let dateString = dateFormatter.string(from: date)
            let cacheKey = "\(location.coordinate.latitude),\(location.coordinate.longitude)_\(dateString)"
            if let cached = cachedSunriseSunsetTimes[cacheKey],
               Date().timeIntervalSince(cached.timestamp) < cacheExpirationInterval {
                cachedResults.append((cached.sunrise, cached.sunset))
            } else {
                allCached = false
                break
            }
        }

        if allCached && cachedResults.count == days { return cachedResults }

        // Fetch from WeatherKit (single API call returns multiple days)
        do {
            let forecast = try await weatherService.weather(for: location, including: .daily)
            var results: [(sunrise: Date?, sunset: Date?)] = []

            for i in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: i, to: startDate) else {
                    results.append((nil, nil))
                    continue
                }
                if let dayForecast = forecast.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                    let result = (sunrise: dayForecast.sun.sunrise, sunset: dayForecast.sun.sunset)
                    let dateString = dateFormatter.string(from: date)
                    let cacheKey = "\(location.coordinate.latitude),\(location.coordinate.longitude)_\(dateString)"
                    cachedSunriseSunsetTimes[cacheKey] = (result.sunrise, result.sunset, Date())
                    results.append(result)
                } else {
                    results.append((nil, nil))
                }
            }
            return results
        } catch {
            appLogger.error("Failed to fetch multi-day sun times: \(error.localizedDescription)")
            return Array(repeating: (nil, nil), count: days)
        }
    }
    
    /// Récupère les données météo complètes pour une localisation
    func fetchWeather(for location: CLLocation) async {
        isLoading = true
        errorMessage = nil

        do {
            let weather = try await weatherService.weather(for: location)
            self.currentWeather = weather.currentWeather
            self.dailyForecast = weather.dailyForecast.forecast
            self.hourlyForecast = weather.hourlyForecast.forecast
            self.isLoading = false
        } catch {
            self.errorMessage = "Erreur: \(error.localizedDescription)"
            self.isLoading = false
            appLogger.error("Erreur météo: \(error)")
        }
    }
    
    /// Obtient le symbole SF approprié pour une condition météo
    func getWeatherSymbol(for condition: WeatherKit.WeatherCondition) -> String {
        switch condition {
        case .clear:
            return "sun.max.fill"
        case .cloudy:
            return "cloud.fill"
        case .mostlyClear, .mostlyCloudy, .partlyCloudy:
            return "cloud.sun.fill"
        case .foggy:
            return "cloud.fog.fill"
        case .haze, .smoky:
            return "sun.haze.fill"
        case .drizzle, .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms:
            return "cloud.bolt.rain.fill"
        case .breezy, .windy:
            return "wind"
        case .frigid, .blizzard, .blowingSnow, .freezingDrizzle, .freezingRain, .heavySnow, .snow, .flurries, .sleet, .wintryMix:
            return "snowflake"
        case .heavyRain, .rain, .sunShowers:
            return "cloud.rain.fill"
        case .hot:
            return "thermometer.sun.fill"
        case .hurricane, .tropicalStorm:
            return "tornado"
        default:
            return "cloud.fill"
        }
    }
}

// L'énumération WeatherCondition est déjà définie dans WeatherKit
// enum WeatherCondition: String, Codable {
//     ...
// } 