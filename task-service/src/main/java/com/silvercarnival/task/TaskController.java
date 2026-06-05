package com.silvercarnival.task;

import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/task")
public class TaskController {

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("service", "task-service", "status", "UP");
    }
}
