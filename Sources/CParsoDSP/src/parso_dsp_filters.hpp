#pragma once

#include <cmath>

namespace parso_dsp_detail {

constexpr double kPi = 3.14159265358979323846;
constexpr double kMinimumGainDB = -120.0;
constexpr double kMaximumGainDB = 6.0;

struct Biquad {
    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a1 = 0.0;
    double a2 = 0.0;
    double x1 = 0.0;
    double x2 = 0.0;
    double y1 = 0.0;
    double y2 = 0.0;

    void setLowShelf(double sampleRate, double frequency, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double sine = std::sin(w0);
        const double alpha = sine * 0.5 * std::sqrt(2.0);
        const double beta = 2.0 * std::sqrt(a) * alpha;
        setCoefficients(
            a * ((a + 1.0) - (a - 1.0) * cosine + beta),
            2.0 * a * ((a - 1.0) - (a + 1.0) * cosine),
            a * ((a + 1.0) - (a - 1.0) * cosine - beta),
            (a + 1.0) + (a - 1.0) * cosine + beta,
            -2.0 * ((a - 1.0) + (a + 1.0) * cosine),
            (a + 1.0) + (a - 1.0) * cosine - beta
        );
    }

    void setHighShelf(double sampleRate, double frequency, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double sine = std::sin(w0);
        const double alpha = sine * 0.5 * std::sqrt(2.0);
        const double beta = 2.0 * std::sqrt(a) * alpha;
        setCoefficients(
            a * ((a + 1.0) + (a - 1.0) * cosine + beta),
            -2.0 * a * ((a - 1.0) + (a + 1.0) * cosine),
            a * ((a + 1.0) + (a - 1.0) * cosine - beta),
            (a + 1.0) - (a - 1.0) * cosine + beta,
            2.0 * ((a - 1.0) - (a + 1.0) * cosine),
            (a + 1.0) - (a - 1.0) * cosine - beta
        );
    }

    void setPeaking(double sampleRate, double frequency, double q, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        setCoefficients(
            1.0 + alpha * a, -2.0 * cosine, 1.0 - alpha * a,
            1.0 + alpha / a, -2.0 * cosine, 1.0 - alpha / a
        );
    }

    void setLowPass(double sampleRate, double frequency, double q) {
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        setCoefficients(
            (1.0 - cosine) * 0.5, 1.0 - cosine, (1.0 - cosine) * 0.5,
            1.0 + alpha, -2.0 * cosine, 1.0 - alpha
        );
    }

    void setHighPass(double sampleRate, double frequency, double q) {
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        setCoefficients(
            (1.0 + cosine) * 0.5, -(1.0 + cosine), (1.0 + cosine) * 0.5,
            1.0 + alpha, -2.0 * cosine, 1.0 - alpha
        );
    }

    float process(float input) {
        const double x = static_cast<double>(input);
        const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        return static_cast<float>(y);
    }

private:
    void setCoefficients(double rawB0, double rawB1, double rawB2,
                         double rawA0, double rawA1, double rawA2) {
        b0 = rawB0 / rawA0;
        b1 = rawB1 / rawA0;
        b2 = rawB2 / rawA0;
        a1 = rawA1 / rawA0;
        a2 = rawA2 / rawA0;
    }
};
inline double sanitizedDB(float db) {
    if (std::isnan(db)) return 0.0;
    if (std::isinf(db) && db < 0.0f) return kMinimumGainDB;
    return std::fmax(kMinimumGainDB,
                     std::fmin(kMaximumGainDB, static_cast<double>(db)));
}

inline double sanitizedWarm2DB(float db, double minimumDB) {
    if (std::isnan(db)) return 0.0;
    if (std::isinf(db) && db < 0.0f) return kMinimumGainDB;
    return std::fmax(minimumDB,
                     std::fmin(12.0, static_cast<double>(db)));
}

} // namespace parso_dsp_detail
