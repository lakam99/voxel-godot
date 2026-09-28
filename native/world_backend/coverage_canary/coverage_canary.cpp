int intentionally_uncovered_function() {
    return 17;
}

int classify_canary_value(const int value) {
    if (value > 0) {
        return 1;
    }
    return 0;
}

int main() {
    return classify_canary_value(1) == 1 ? 0 : 1;
}
