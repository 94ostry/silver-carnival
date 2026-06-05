package com.silvercarnival.core;

import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/core")
public class CoreController {

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("service", "core-service", "status", "UP");
    }
}
